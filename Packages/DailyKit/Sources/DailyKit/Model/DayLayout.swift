import Foundation

/// 一天里某个日程块的横向位置，用占列宽的比例表示。
public struct PositionedItem: Identifiable, Sendable {
    public let item: CalendarItem
    /// 左边距（0…1）。
    public let x: Double
    /// 宽度（0…1）。
    public let width: Double
    public var id: UUID { item.id }
}

/// 重叠日程的横向排布：重叠的日程左右并排、互不遮挡；
/// 某个日程右侧的栏在它整个时段内都空着时，就向右扩展占满，尽量多给文字留宽度。
public enum DayLayout {
    /// 显示时每个块至少占的时长，避免「快递待取件」这类时间点条目挤成一条线。
    public static let minimumVisualDuration: TimeInterval = 30 * 60

    private static func visualEnd(_ item: CalendarItem) -> Date {
        max(item.effectiveEnd, item.start.addingTimeInterval(minimumVisualDuration))
    }

    private static func overlaps(_ a: CalendarItem, _ b: CalendarItem) -> Bool {
        a.start < visualEnd(b) && b.start < visualEnd(a)
    }

    public static func layout(_ items: [CalendarItem]) -> [PositionedItem] {
        let sorted = items.sorted { ($0.start, $0.effectiveEnd) < ($1.start, $1.effectiveEnd) }
        var result: [PositionedItem] = []
        var cluster: [(item: CalendarItem, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let columns = columnEnds.count
            for (item, column) in cluster {
                var span = 1
                while column + span < columns,
                      !cluster.contains(where: { $0.column == column + span && overlaps($0.item, item) }) {
                    span += 1
                }
                result.append(PositionedItem(item: item, x: Double(column) / Double(columns),
                                             width: Double(span) / Double(columns)))
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
