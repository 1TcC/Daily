import Foundation

/// 某一天的安排（「接下来几天」小组件用）。
public struct DayAgenda: Sendable, Identifiable {
    public var date: Date
    public var items: [CalendarItem]
    public var id: Date { date }

    public init(date: Date, items: [CalendarItem]) {
        self.date = date
        self.items = items
    }
}

/// 小组件一次刷新所需的全部数据，由 Widget 的 TimelineProvider 从存储读取。
public struct WidgetSnapshot: Sendable {
    public var date: Date
    /// 今天的条目（含全天），按开始时间排序。
    public var today: [CalendarItem]
    public var tomorrowCount: Int
    public var tomorrowFirst: CalendarItem?
    /// 未来 14 天内最近的一次出行。
    public var nextTrip: CalendarItem?
    public var monthlySubscriptionCost: Decimal
    public var subscriptionCount: Int
    public var nextRenewal: (subscription: Subscription, date: Date)?
    public var pendingCount: Int
    /// 从今天起 7 天的安排；今天只保留还没结束的。
    public var days: [DayAgenda] = []

    /// 正在进行的条目。
    public var current: CalendarItem? {
        today.first { !$0.isAllDay && $0.end != nil && $0.start <= date && date < $0.effectiveEnd }
    }

    /// 下一个还没开始的条目。
    public var next: CalendarItem? {
        today.first { !$0.isAllDay && $0.start > date }
    }

    public static func load(from store: ItemStore, now: Date = .now, calendar: Calendar = .mondayFirst) throws -> WidgetSnapshot {
        let dayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let today = try store.items(in: DateInterval(start: dayStart, end: tomorrow))
            .filter { $0.start >= dayStart || !$0.isAllDay }
        let tomorrowItems = try store.items(in: DateInterval(start: tomorrow, end: dayAfter)).filter { $0.start >= tomorrow }
        let horizon = calendar.date(byAdding: .day, value: 14, to: dayStart)!
        let nextTrip = try store.items(in: DateInterval(start: now, end: horizon))
            .first { $0.sourceKind == .travel && $0.start >= now }

        let subs = try store.subscriptions().filter(\.isActive)
        let nextRenewal = subs
            .compactMap { sub in sub.nextRenewal(after: now, calendar: calendar).map { (sub, $0) } }
            .min { $0.1 < $1.1 }

        var days: [DayAgenda] = []
        for offset in 0..<7 {
            let start = calendar.date(byAdding: .day, value: offset, to: dayStart)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let items = try store.items(in: DateInterval(start: start, end: end)).filter { item in
                // 全天日程的结束是「次日零点」（不含），不能算到下一天；定时日程只算当天开始的；
                // 今天已经结束的不再占位置
                let onDay = item.isAllDay ? item.effectiveEnd > start : item.start >= start
                return onDay && (offset > 0 || item.isAllDay || item.effectiveEnd > now)
            }
            days.append(DayAgenda(date: start, items: items))
        }

        return WidgetSnapshot(
            date: now,
            today: today,
            tomorrowCount: tomorrowItems.count,
            tomorrowFirst: tomorrowItems.first { !$0.isAllDay } ?? tomorrowItems.first,
            nextTrip: nextTrip,
            monthlySubscriptionCost: subs.reduce(0) { $0 + $1.monthlyCost },
            subscriptionCount: subs.count,
            nextRenewal: nextRenewal.map { (subscription: $0.0, date: $0.1) },
            pendingCount: try store.pendingItems().count,
            days: days
        )
    }

    /// 小组件的刷新时间点：每个条目开始和结束时刷新一次，保证「进行中 / 下一项」准确。
    public func refreshDates(calendar: Calendar = .mondayFirst) -> [Date] {
        let boundaries = today.flatMap { [$0.start, $0.effectiveEnd] }.filter { $0 > date }
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        return [date] + Array(Set(boundaries + [midnight])).sorted()
    }

    public static let placeholder = WidgetSnapshot(
        date: .now, today: [], tomorrowCount: 0, tomorrowFirst: nil, nextTrip: nil,
        monthlySubscriptionCost: 0, subscriptionCount: 0, nextRenewal: nil, pendingCount: 0
    )
}
