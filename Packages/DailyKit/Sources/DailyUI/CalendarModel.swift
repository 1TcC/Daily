import DailyKit
import Foundation
import Observation
import SwiftUI

public enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case day = "日"
    case week = "周"
    case month = "月"
    case list = "列表"
    public var id: Self { self }
}

/// 与 Grok 中转服务的连接状态。
public struct RelayStatus: Sendable {
    /// Grok 的连接器地址；其他 AI 在后面加 `/<名字>`。
    public var mcpURL: URL
    public var lastSync: Date?
    public var error: String?
    /// 实时推送连接是否在线。
    public var isLive = false
    /// 只读的 iPhone 日历订阅地址。
    public var calendarFeedURL: URL

    public init(mcpURL: URL, calendarFeedURL: URL, lastSync: Date? = nil, error: String? = nil) {
        self.mcpURL = mcpURL
        self.calendarFeedURL = calendarFeedURL
        self.lastSync = lastSync
        self.error = error
    }
}

/// 需要 App 层（同步、授权）处理的操作，由 App 注入，DailyUI 本身不管数据来源。
@MainActor
public struct CalendarActions {
    public var requestCalendarAccess: () -> Void = {}
    public var setCalendarIncluded: (_ calendarID: String, _ included: Bool) -> Void = { _, _ in }
    public var disconnectRelay: () -> Void = {}
    /// 把短信生成的取件条目标记为已取件。
    public var markParcelPicked: (CalendarItem) -> Void = { _ in }
    /// 同步全部来源（工具栏刷新按钮）。
    public var refresh: () -> Void = {}
    public var syncRelay: () -> Void = {}
    /// 从教务系统导入了新课表。
    public var importCourseSchedule: (CourseSchedule) -> Void = { _ in }
    /// 显示范围变了（翻页、切换视图），App 可以据此补同步该范围。
    public var visibleRangeChanged: (DateInterval) -> Void = { _ in }
    /// 手动日程增删改后：刷新小组件、提醒和上传快照。
    public var itemsChanged: () -> Void = {}
    /// 订阅增删改后：重新生成续费条目。
    public var subscriptionsChanged: () -> Void = {}
    /// 提醒设置变了：重新安排通知。
    public var remindersChanged: () -> Void = {}
    public var requestNotificationAccess: () -> Void = {}
    public var sendTestNotification: () -> Void = {}
    public var setLaunchAtLogin: (Bool) -> Void = { _ in }
    /// 粘贴中转服务地址连接（返回地址是否有效）。
    public var connectRelay: (String) -> Bool = { _ in false }
    public var setRelayPublicHost: (String?) -> Void = { _ in }
    public init() {}
}

/// 系统通知权限。
public enum NotificationAccess: Sendable {
    case notDetermined, granted, denied
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
    public var showingCourseImport = false
    public var isSyncing = false
    /// 已连接 Grok 中转服务时非空。
    public var relay: RelayStatus?
    /// 已导入的课表，用于侧边栏摘要和显示教学周。
    public var courseSchedule: CourseSchedule?
    /// 主窗口字体缩放，见 `TextScale`。
    public var textScale = CGFloat(Preferences.shared.textScale) {
        didSet { Preferences.shared.textScale = Double(textScale) }
    }
    public var actions = CalendarActions()

    /// 正在新建 / 编辑的日程（弹出编辑表单）。
    public var editor: EventDraft?
    public var showingSubscriptions = false
    /// 搜索框内容；非空时主区域显示搜索结果。
    public var searchText = "" { didSet { runSearch() } }
    public private(set) var searchResults: [CalendarItem] = []
    /// 搜索框是否获得焦点（⌘F）。
    public var searchPresented = false

    // 设置
    public var launchAtLogin = false
    public var notificationAccess: NotificationAccess = .notDetermined
    public var reminderSettings = Preferences.shared.reminders {
        didSet {
            guard reminderSettings != oldValue else { return }
            Preferences.shared.reminders = reminderSettings
            actions.remindersChanged()
        }
    }
    /// 时间轴默认从几点开始。
    public var timelineDefaultHour = Preferences.shared.timelineStartHour {
        didSet { Preferences.shared.timelineStartHour = timelineDefaultHour }
    }
    public var showMenuBarIcon = Preferences.shared.showMenuBarIcon {
        didSet { Preferences.shared.showMenuBarIcon = showMenuBarIcon }
    }

    // 系统日历
    public var calendarAccess: CalendarAccess = .notDetermined
    public var systemCalendars: [SystemCalendarInfo] = []
    public var excludedCalendarIDs: Set<String> = []
    /// 系统日历子列表是否展开；默认收起，记住用户的选择。
    public var systemCalendarsExpanded = Preferences.shared.systemCalendarsExpanded {
        didSet { Preferences.shared.systemCalendarsExpanded = systemCalendarsExpanded }
    }
    public private(set) var items: [CalendarItem] = []
    public private(set) var pending: [CalendarItem] = []
    /// 还没取的快递（短信生成的取件条目，最近 14 天），按收到时间倒序。
    public private(set) var pendingParcels: [CalendarItem] = []
    public private(set) var subscriptions: [Subscription] = []
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
            // 连同前后相邻的一页一起加载，翻页拖动时相邻页也有数据。
            items = try store.items(in: loadedInterval)
            pending = try store.pendingItems()
            pendingParcels = try store.pendingParcels(now: now())
            subscriptions = try store.subscriptions()
            if !searchText.isEmpty { runSearch() }
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

    public var visibleDays: [Date] { days(for: anchorDate) }

    /// 某一页（由该页内任意一天 `anchor` 确定）要显示的日期。
    public func days(for anchor: Date) -> [Date] {
        switch mode {
        case .day:
            return [calendar.startOfDay(for: anchor)]
        case .week, .list:
            let start = calendar.startOfWeek(for: anchor)
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        case .month:
            return monthGridDays(for: anchor)
        }
    }

    public var visibleInterval: DateInterval { interval(of: visibleDays) }

    /// 上一页、当前页、下一页的定位日期，翻页时三页并排渲染。
    public var pageAnchors: [Date] { [anchor(offsetBy: -1), anchorDate, anchor(offsetBy: 1)] }

    private var loadedInterval: DateInterval {
        let first = days(for: anchor(offsetBy: -1)), last = days(for: anchor(offsetBy: 1))
        return DateInterval(start: first.first!, end: interval(of: last).end)
    }

    private func interval(of days: [Date]) -> DateInterval {
        DateInterval(start: days.first!, end: calendar.date(byAdding: .day, value: 1, to: days.last!)!)
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

    public func anchor(offsetBy delta: Int) -> Date {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week, .list: .weekOfYear
        case .month: .month
        }
        return calendar.date(byAdding: component, value: delta, to: anchorDate) ?? anchorDate
    }

    public func step(_ delta: Int) { anchorDate = anchor(offsetBy: delta) }

    public func goToToday() { anchorDate = now() }

    public func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: now()) }

    public var title: String { anchorDate.formatted("yyyy年M月", calendar: calendar) }

    public var subtitle: String {
        switch mode {
        case .day: anchorDate.formatted("EEEE", calendar: calendar)
        case .week, .list:
            if let schedule = courseSchedule, let week = schedule.week(of: anchorDate, calendar: calendar),
               week <= max(schedule.lastWeek, 1) + 2 {
                "教学第 \(week) 周"
            } else {
                "第 \(calendar.component(.weekOfYear, from: anchorDate)) 周"
            }
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

    /// 周 / 日视图时间轴从几点开始：默认 7 点，这几页里有更早开始的日程就提前到那个整点。
    /// 前一天开始、跨过午夜的日程不算，避免把时间轴撑回 0 点。
    public func timelineStartHour(for anchors: [Date]) -> Int {
        var hour = timelineDefaultHour
        for anchor in anchors {
            for day in days(for: anchor) {
                for item in timedItems(on: day) where calendar.isDate(item.start, inSameDayAs: day) {
                    hour = min(hour, calendar.component(.hour, from: item.start))
                }
            }
        }
        return hour
    }

    public func count(of kind: SourceKind) -> Int {
        let interval = visibleInterval
        return items.filter { $0.sourceKind == kind && $0.overlaps(interval) }.count
    }

    public func toggle(_ kind: SourceKind) {
        if hiddenKinds.contains(kind) { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
    }

    // MARK: - 新建 / 编辑

    /// 新建日程：给了时间就从那个时间开始；否则当前页是今天就取下一个整点，别的日子取 9 点。
    public func newEvent(at start: Date? = nil) {
        let start = start ?? {
            let now = now()
            if calendar.isDate(anchorDate, inSameDayAs: now) || mode != .day && visibleInterval.contains(now) {
                return calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: anchorDate) ?? anchorDate
        }()
        editor = EventDraft(start: start, calendar: calendar)
    }

    public func edit(_ item: CalendarItem) {
        guard item.isEditable else { return }
        editor = EventDraft(item: item, calendar: calendar)
    }

    public func save(_ draft: EventDraft) {
        try? store.save(draft.item(calendar: calendar))
        editor = nil
        reload()
        actions.itemsChanged()
    }

    public func delete(_ item: CalendarItem) {
        guard item.isEditable else { return }
        try? store.delete(id: item.id)
        if editor?.id == item.id { editor = nil }
        reload()
        actions.itemsChanged()
    }

    // MARK: - 订阅

    public func save(_ subscription: Subscription) {
        try? store.save(subscription)
        reload()
        actions.subscriptionsChanged()
    }

    public func deleteSubscription(_ subscription: Subscription) {
        try? store.deleteSubscription(id: subscription.id)
        reload()
        actions.subscriptionsChanged()
    }

    // MARK: - 搜索

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        searchResults = query.isEmpty ? [] : ((try? store.search(query)) ?? [])
    }

    /// 从搜索结果跳到这个日程所在的那一页。
    public func reveal(_ item: CalendarItem) {
        if mode == .month || mode == .list { mode = .week }
        anchorDate = item.start
        searchText = ""
    }

    // MARK: - 待确认

    public func confirm(_ item: CalendarItem) { updateStatus(.confirmed, item) }
    public func dismiss(_ item: CalendarItem) { updateStatus(.dismissed, item) }

    private func updateStatus(_ status: ItemStatus, _ item: CalendarItem) {
        try? store.setStatus(status, for: item.id)
        reload()
    }
}
