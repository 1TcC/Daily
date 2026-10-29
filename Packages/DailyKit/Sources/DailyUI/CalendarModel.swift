import DailyKit
import Foundation
import Observation

public enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case day = "日"
    case week = "周"
    case month = "月"
    case list = "列表"
    public var id: Self { self }
}

/// 需要 App 层（同步、授权）处理的操作，由 App 注入，DailyUI 本身不管数据来源。
@MainActor
public struct CalendarActions {
    public var requestCalendarAccess: () -> Void = {}
    public var setCalendarIncluded: (_ calendarID: String, _ included: Bool) -> Void = { _, _ in }
    /// 显示范围变了（翻页、切换视图），App 可以据此补同步该范围。
    public var visibleRangeChanged: (DateInterval) -> Void = { _ in }
    public init() {}
}

/// 主窗口的状态：当前显示的日期范围、隐藏的来源、从存储读出的条目。
@MainActor @Observable
public final class CalendarModel {
    public let store: ItemStore
    public let calendar: Calendar
    public var mode: ViewMode = .week { didSet { rangeDidChange() } }
    public var anchorDate: Date { didSet { rangeDidChange() } }
    public var hiddenKinds: Set<SourceKind> = []
    public var lastSync: Date?
    public var showingInbox = false
    public var actions = CalendarActions()

    // 系统日历
    public var calendarAccess: CalendarAccess = .notDetermined
    public var systemCalendars: [SystemCalendarInfo] = []
    public var excludedCalendarIDs: Set<String> = []
    public var systemCalendarsExpanded = true
    public private(set) var items: [CalendarItem] = []
    public private(set) var pending: [CalendarItem] = []
    public private(set) var loadError: String?
    /// 「现在」，测试和截图时可以固定。
    public var now: () -> Date

    public init(store: ItemStore, calendar: Calendar = .mondayFirst, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.anchorDate = now()
        reload()
    }

    public func reload() {
        do {
            items = try store.items(in: visibleInterval)
            pending = try store.pendingItems()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    private func rangeDidChange() {
        reload()
        actions.visibleRangeChanged(visibleInterval)
    }

    public func setCalendar(_ id: String, included: Bool) {
        if included { excludedCalendarIDs.remove(id) } else { excludedCalendarIDs.insert(id) }
        actions.setCalendarIncluded(id, included)
    }

    /// 按账户分组的系统日历，保持账户出现的顺序。
    public var calendarsByAccount: [(account: String, calendars: [SystemCalendarInfo])] {
        var order: [String] = []
        var groups: [String: [SystemCalendarInfo]] = [:]
        for cal in systemCalendars {
            if groups[cal.accountName] == nil { order.append(cal.accountName) }
            groups[cal.accountName, default: []].append(cal)
        }
        return order.map { ($0, groups[$0]!) }
    }

    // MARK: - 日期范围

    public var visibleDays: [Date] {
        switch mode {
        case .day:
            return [calendar.startOfDay(for: anchorDate)]
        case .week, .list:
            let start = calendar.startOfWeek(for: anchorDate)
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            return monthGridDays(for: anchorDate)
        }
    }

    public var visibleInterval: DateInterval {
        let days = visibleDays
        let end = calendar.date(byAdding: .day, value: 1, to: days.last!)!
        return DateInterval(start: days.first!, end: end)
    }

    /// 月视图需要的完整周（含上月末、下月初）。
    public func monthGridDays(for date: Date) -> [Date] {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let gridStart = calendar.startOfWeek(for: monthStart)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        var days: [Date] = []
        var d = gridStart
        while d < monthEnd || days.count % 7 != 0 {
            days.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        return days
    }

    public func step(_ delta: Int) {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week, .list: .weekOfYear
        case .month: .month
        }
        anchorDate = calendar.date(byAdding: component, value: delta, to: anchorDate) ?? anchorDate
    }

    public func goToToday() { anchorDate = now() }

    public func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now()) }

    public var title: String { anchorDate.formatted("yyyy年M月", calendar: calendar) }

    public var subtitle: String {
        switch mode {
        case .day: anchorDate.formatted("EEEE", calendar: calendar)
        case .week, .list: "第 \(calendar.component(.weekOfYear, from: anchorDate)) 周"
        case .month: ""
        }
    }

    // MARK: - 条目

    var visibleItems: [CalendarItem] { items.filter { !hiddenKinds.contains($0.sourceKind) } }

    public func timedItems(on day: Date) -> [CalendarItem] {
        let interval = dayInterval(day)
        return visibleItems.filter { !$0.isAllDay && $0.overlaps(interval) }
    }

    public func allDayItems(on day: Date) -> [CalendarItem] {
        let interval = dayInterval(day)
        return visibleItems.filter { $0.isAllDay && $0.start < interval.end && $0.effectiveEnd > interval.start }
    }

    public func items(on day: Date) -> [CalendarItem] {
        allDayItems(on: day) + timedItems(on: day)
    }

    public func dayInterval(_ day: Date) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    public func count(of kind: SourceKind) -> Int { items.filter { $0.sourceKind == kind }.count }

    public func toggle(_ kind: SourceKind) {
        if hiddenKinds.contains(kind) { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
    }

    // MARK: - 待确认

    public func confirm(_ item: CalendarItem) { updateStatus(.confirmed, item) }
    public func dismiss(_ item: CalendarItem) { updateStatus(.dismissed, item) }

    private func updateStatus(_ status: ItemStatus, _ item: CalendarItem) {
        try? store.setStatus(status, for: item.id)
        reload()
    }
}
