import Foundation

/// 一天里某个日程块的横向位置，用占列宽的比例表示。
public struct PositionedItem: Identifiable, Sendable {
    public let item: CalendarItem
    /// 左边距（0…1）。
    public let x: Double
    /// 宽度（0…1）。
    public let width: Double
    /// 是否压在别的日程上面（错开叠放时为 true），需要描边区分。
    public let isStacked: Bool
    public var id: UUID { item.id }
}

/// 重叠日程的横向排布：
/// - 同一簇里开始时间都错开 20 分钟以上：错开叠放，后开始的向右缩进、延伸到列的右边，压在前一个上面，
///   这样前一个的标题仍露在顶部，后一个也有足够的宽度。
/// - 有日程几乎同时开始：左右并排平分，否则标题会被挡住。
public enum DayLayout {
    /// 显示时每个块至少占的时长，避免「快递待取件」这类时间点条目挤成一条线。
    public static let minimumVisualDuration: TimeInterval = 30 * 60
    /// 开始时间相差不到这个值就算「同时开始」。
    public static let sameStartThreshold: TimeInterval = 20 * 60

    private static func visualEnd(_ item: CalendarItem) -> Date {
        max(item.effectiveEnd, item.start.addingTimeInterval(minimumVisualDuration))
    }

    public static func layout(_ items: [CalendarItem]) -> [PositionedItem] {
        let sorted = items.sorted { ($0.start, $0.effectiveEnd) < ($1.start, $1.effectiveEnd) }
        var result: [PositionedItem] = []
        var cluster: [(item: CalendarItem, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let columns = columnEnds.count
            let starts = cluster.map(\.item.start)
            let together = zip(starts, starts.dropFirst()).contains { $1.timeIntervalSince($0) < sameStartThreshold }
            // 叠放层级：开始时还在进行的日程里最深的一层再往里缩一层。
            // 不能直接用列号——一列空出来后会被更晚的日程重新占用，按列号缩进会把中间那个整个盖住。
            var levels: [Int] = []
            for (k, entry) in cluster.enumerated() {
                let active = cluster[..<k].indices.filter { visualEnd(cluster[$0].item) > entry.item.start }
                levels.append((active.map { levels[$0] }.max() ?? -1) + 1)
            }
            let step = 1 / Double((levels.max() ?? 0) + 2)
            for ((item, column), level) in zip(cluster, levels) {
                if columns <= 1 {
                    result.append(PositionedItem(item: item, x: 0, width: 1, isStacked: false))
                } else if together {
                    result.append(PositionedItem(item: item, x: Double(column) / Double(columns),
                                                 width: 1 / Double(columns), isStacked: false))
                } else {
                    let indent = Double(level) * step
                    result.append(PositionedItem(item: item, x: indent, width: 1 - indent, isStacked: level > 0))
                }
            }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for item in sorted {
            let end = visualEnd(item)
            if item.start >= clusterEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = end
                cluster.append((item, free))
            } else {
                columnEnds.append(end)
                cluster.append((item, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return result
    }
}
