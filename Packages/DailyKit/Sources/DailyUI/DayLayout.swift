import DailyKit
import Foundation

/// 一天内重叠日程的分栏结果：`column` 是所在栏，`columns` 是这一簇重叠日程共有几栏。
struct PositionedItem: Identifiable {
    let item: CalendarItem
    let column: Int
    let columns: Int
    var id: UUID { item.id }
}

enum DayLayout {
    /// 显示时每个块至少占的时长，避免「快递待取件」这类时间点条目挤成一条线。
    static let minimumVisualDuration: TimeInterval = 30 * 60

    static func layout(_ items: [CalendarItem]) -> [PositionedItem] {
        let sorted = items.sorted { ($0.start, $0.effectiveEnd) < ($1.start, $1.effectiveEnd) }
        var result: [PositionedItem] = []
        var cluster: [(item: CalendarItem, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            result += cluster.map { PositionedItem(item: $0.item, column: $0.column, columns: columnEnds.count) }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for item in sorted {
            let end = max(item.effectiveEnd, item.start.addingTimeInterval(minimumVisualDuration))
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
