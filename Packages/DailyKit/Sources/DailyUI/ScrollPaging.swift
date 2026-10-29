import AppKit
import SwiftUI

/// 触控板双指滑动翻页：滑动时内容跟手移动，松手超过阈值就翻到上一页 / 下一页。
/// `vertical` 为 false 时，上下滑动交给内容自己滚动（例如周视图的时间轴）。
struct ScrollPaging: ViewModifier {
    let vertical: Bool
    /// -1 上一页，+1 下一页；第二个参数表示是否是上下滑动触发的。
    let onPage: (Int, Bool) -> Void

    @State private var offset: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .background(
                ScrollEventCatcher(vertical: vertical) { offset = $0 } onEnd: { page, isVertical in
                    withAnimation(.easeOut(duration: 0.22)) {
                        offset = .zero
                        if page != 0 { onPage(page, isVertical) }
                    }
                }
            )
    }
}

extension View {
    func scrollPaging(vertical: Bool = false, onPage: @escaping (Int, Bool) -> Void) -> some View {
        modifier(ScrollPaging(vertical: vertical, onPage: onPage))
    }
}

/// 用本地事件监听拿到滚轮 / 触控板事件，判断手势方向后决定自己处理还是放行给 ScrollView。
private struct ScrollEventCatcher: NSViewRepresentable {
    let vertical: Bool
    let onChange: (CGSize) -> Void
    let onEnd: (Int, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        enum Axis { case undecided, horizontal, vertical, passthrough }

        var parent: ScrollEventCatcher
        weak var view: NSView?
        private var monitor: Any?
        private var axis: Axis = .undecided
        private var total: CGSize = .zero
        /// 本次手势由我们处理时，松手后的惯性滚动也一并吞掉。
        private var swallowMomentum = false
        private var lastWheelPage = Date.distantPast

        /// 松手时超过这个距离就翻页。
        private let threshold: CGFloat = 60
        /// 跟手位移的阻尼，避免内容被拖得太远。
        private let damping: CGFloat = 0.5

        init(parent: ScrollEventCatcher) {
            self.parent = parent
        }

        func install() {
            // 本地监听总在主线程回调；NSEvent 不是 Sendable，只把「是否吞掉」带出主线程隔离区。
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point)
        }

        /// 返回 true 表示这个事件由翻页手势处理，不再传给 ScrollView。
        private func consumes(_ event: NSEvent) -> Bool {
            // 鼠标滚轮：没有手势阶段，一格一页，加个冷却避免连翻。
            guard event.hasPreciseScrollingDeltas else {
                guard contains(event) else { return false }
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                let delta = abs(dx) > abs(dy) ? dx : (parent.vertical ? dy : 0)
                guard delta != 0 else { return false }
                if Date().timeIntervalSince(lastWheelPage) > 0.25 {
                    lastWheelPage = Date()
                    parent.onEnd(delta > 0 ? -1 : 1, delta == dy && abs(dy) > abs(dx))
                }
                return true
            }

            // 惯性阶段
            if event.phase.isEmpty, !event.momentumPhase.isEmpty {
                return swallowMomentum
            }

            if event.phase.contains(.began) {
                guard contains(event) else {
                    axis = .passthrough
                    return false
                }
                axis = .undecided
                total = .zero
                swallowMomentum = false
            }

            if event.phase.contains(.began) || event.phase.contains(.changed) {
                total.width += event.scrollingDeltaX
                total.height += event.scrollingDeltaY
                if axis == .undecided, hypot(total.width, total.height) > 4 {
                    if abs(total.width) > abs(total.height) {
                        axis = .horizontal
                    } else {
                        axis = parent.vertical ? .vertical : .passthrough
                    }
                }
                switch axis {
                case .horizontal:
                    parent.onChange(CGSize(width: total.width * damping, height: 0))
                    return true
                case .vertical:
                    parent.onChange(CGSize(width: 0, height: total.height * damping))
                    return true
                case .undecided:
                    return true
                case .passthrough:
                    return false
                }
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                defer { axis = .undecided }
                // 内容跟手方向：向右 / 向下拖表示看上一页。
                let distance: CGFloat
                switch axis {
                case .horizontal: distance = total.width
                case .vertical: distance = total.height
                case .undecided:
                    parent.onEnd(0, false)
                    return true
                case .passthrough: return false
                }
                swallowMomentum = true
                let cancelled = event.phase.contains(.cancelled)
                parent.onEnd(!cancelled && abs(distance) > threshold ? (distance > 0 ? -1 : 1) : 0, axis == .vertical)
                return true
            }

            return axis != .passthrough
        }
    }
}
