import AppKit
import SwiftUI

/// 翻页状态：上一页 / 当前页 / 下一页并排摆放，`offset` 是手指拖动的位移。
/// 只有 `PagedStrip` 读取它，拖动时只重绘这几条，不触发整页重新布局。
@MainActor @Observable
final class Pager {
    var offset: CGFloat = 0
    /// 一页的长度（横向翻页是宽度，纵向是高度），由 PagedStrip 测量后写入。
    var length: CGFloat = 0
    private(set) var isAnimating = false

    func drag(to value: CGFloat) {
        guard !isAnimating, length > 0 else { return }
        offset = min(length, max(-length, value))
    }

    /// 松手或点按钮：`page` 为 ±1 时滑完这一页再调用 `commit` 切换数据，为 0 时弹回原位。
    func finish(_ page: Int, commit: @escaping @MainActor () -> Void) {
        guard !isAnimating else { return }
        guard page != 0 else {
            withAnimation(.snappy(duration: 0.25)) { offset = 0 }
            return
        }
        guard length > 0 else {
            commit()
            return
        }
        isAnimating = true
        withAnimation(.snappy(duration: 0.3)) {
            offset = page > 0 ? -length : length
        } completion: { [self] in
            // 换成新数据的同时把位移归零：新的「当前页」正好在原来「下一页」的位置，画面无缝衔接。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                commit()
                offset = 0
            }
            isAnimating = false
        }
    }

    func reset() {
        offset = 0
    }
}

/// 把三页沿 `axis` 并排，按 `pager.offset` 平移，只露出中间一页。
struct PagedStrip<Page: View>: View {
    let pager: Pager
    let axis: Axis
    let anchors: [Date]
    @ViewBuilder let page: (Date) -> Page

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let shift = -length + pager.offset
            Group {
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        ForEach(anchors, id: \.self) { page($0).frame(width: geo.size.width, height: geo.size.height) }
                    }
                    .offset(x: shift)
                } else {
                    VStack(spacing: 0) {
                        ForEach(anchors, id: \.self) { page($0).frame(width: geo.size.width, height: geo.size.height) }
                    }
                    .offset(y: shift)
                }
            }
            .onAppear { pager.length = length }
            .onChange(of: length) { pager.length = length }
        }
        .clipped()
    }
}

extension View {
    /// 触控板双指沿 `axis` 滑动时驱动 `pager`；另一个方向的滑动照常传给 ScrollView。
    func pagingGesture(_ axis: Axis, pager: Pager, onPage: @escaping @MainActor (Int) -> Void) -> some View {
        background(
            ScrollEventCatcher(axis: axis) { pager.drag(to: $0) } onEnd: { page in
                pager.finish(page) { onPage(page) }
            }
        )
    }
}

/// 用本地事件监听拿到触控板 / 滚轮事件，判断手势方向后决定自己处理还是放行。
private struct ScrollEventCatcher: NSViewRepresentable {
    let axis: Axis
    let onChange: (CGFloat) -> Void
    let onEnd: (Int) -> Void

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
        enum State { case idle, undecided, paging, passthrough }

        var parent: ScrollEventCatcher
        weak var view: NSView?
        private var monitor: Any?
        private var state: State = .idle
        private var total: CGFloat = 0
        private var other: CGFloat = 0
        private var lastDelta: CGFloat = 0
        /// 本次手势由我们处理时，松手后的惯性滚动也一并吞掉。
        private var swallowMomentum = false
        private var lastWheelPage = Date.distantPast

        /// 松手时超过这个距离就翻页；快速轻扫时距离更短也算。
        private let threshold: CGFloat = 80
        private let flickDistance: CGFloat = 20
        private let flickSpeed: CGFloat = 6

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
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        /// 沿翻页方向的位移；正值表示内容向右 / 向下移动，即看上一页。
        private func along(_ event: NSEvent) -> CGFloat {
            parent.axis == .horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        }

        private func across(_ event: NSEvent) -> CGFloat {
            parent.axis == .horizontal ? event.scrollingDeltaY : event.scrollingDeltaX
        }

        /// 返回 true 表示这个事件由翻页手势处理，不再传给 ScrollView。
        private func consumes(_ event: NSEvent) -> Bool {
            // 鼠标滚轮：没有手势阶段，一格一页，加个冷却避免连翻。
            guard event.hasPreciseScrollingDeltas else {
                let delta = along(event)
                guard contains(event), delta != 0, abs(delta) >= abs(across(event)) else { return false }
                if Date().timeIntervalSince(lastWheelPage) > 0.35 {
                    lastWheelPage = Date()
                    parent.onEnd(delta > 0 ? -1 : 1)
                }
                return true
            }

            // 惯性阶段
            if event.phase.isEmpty, !event.momentumPhase.isEmpty {
                return swallowMomentum
            }

            if event.phase.contains(.began) {
                state = contains(event) ? .undecided : .passthrough
                total = 0
                other = 0
                lastDelta = 0
                swallowMomentum = false
            }

            if event.phase.contains(.began) || event.phase.contains(.changed) {
                total += along(event)
                other += across(event)
                lastDelta = along(event)
                if state == .undecided, hypot(total, other) > 3 {
                    state = abs(total) > abs(other) ? .paging : .passthrough
                }
                switch state {
                case .paging:
                    parent.onChange(total)
                    return true
                case .undecided:
                    return true
                case .idle, .passthrough:
                    return false
                }
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                defer { state = .idle }
                switch state {
                case .paging:
                    swallowMomentum = true
                    let cancelled = event.phase.contains(.cancelled)
                    let flick = abs(total) > flickDistance && abs(lastDelta) > flickSpeed && (lastDelta > 0) == (total > 0)
                    let page = !cancelled && (abs(total) > threshold || flick) ? (total > 0 ? -1 : 1) : 0
                    parent.onEnd(page)
                    return true
                case .undecided:
                    parent.onEnd(0)
                    return true
                case .idle, .passthrough:
                    return false
                }
            }

            return state == .paging || state == .undecided
        }
    }
}
