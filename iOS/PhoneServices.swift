import BackgroundTasks
import DailyKit
import DailyUI
import Foundation
import Observation
import UserNotifications
import WidgetKit

/// iPhone 版的数据和同步：日程来自中转服务（Mac 上传的快照 + AI / 短信写入的条目），可选再加本机日历。
/// 本地也存一份 SQLite（App Group 里），离线可看，小组件也读它。
@MainActor @Observable
final class PhoneServices {
    static let refreshTaskID = "com.rain.daily.refresh"
    private static let relayAccount = "relayConnection"

    let store: ItemStore
    let calendar = Calendar.mondayFirst
    private let sync: SyncEngine
    private let systemCalendar = SystemCalendarSource()
    let reminders = ReminderScheduler()
    private var liveChannel: RelayLiveChannel?
    private var reminderTask: Task<Void, Never>?

    private(set) var connection: RelayConnection?
    var client: RelayClient? { connection.map(RelayClient.init) }
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    var error: String?
    private(set) var isLive = false

    /// 列表从哪天开始显示（默认今天）。
    var startDate: Date { didSet { reload() } }
    private(set) var days: [DayAgenda] = []
    private(set) var pendingParcels: [CalendarItem] = []
    /// 每天（当天零点）的日程，月视图和时间轴用。
    private var itemsByDay: [Date: [CalendarItem]] = [:]

    var usesLocalCalendar = Preferences.shared.usesLocalCalendar {
        didSet {
            Preferences.shared.usesLocalCalendar = usesLocalCalendar
            Task {
                if usesLocalCalendar, SystemCalendarSource.access == .notDetermined {
                    await systemCalendar.requestAccess()
                }
                calendarAccess = SystemCalendarSource.access
                await configureSources()
                if !usesLocalCalendar { try? store.deleteItems(sourceID: systemCalendar.sourceID) }
                await syncNow()
            }
        }
    }
    private(set) var calendarAccess = SystemCalendarSource.access
    var notificationAccess: NotificationAccess = .notDetermined
    var reminderSettings: ReminderSettings {
        didSet {
            guard reminderSettings != oldValue else { return }
            Preferences.shared.reminders = reminderSettings
            scheduleReminders()
        }
    }

    init() {
        store = (try? ItemStore(url: AppGroup.databaseURL)) ?? (try! ItemStore.inMemory())
        sync = SyncEngine(store: store)
        startDate = Calendar.mondayFirst.startOfDay(for: .now)
        // 手机本来就会收到取件短信，默认不再重复通知「收到取件码」
        if !Preferences.shared.hasReminderSettings {
            var settings = ReminderSettings()
            settings.parcelOnArrival = false
            Preferences.shared.reminders = settings
        }
        reminderSettings = Preferences.shared.reminders
        if let saved = Keychain.string(for: Self.relayAccount) { connection = RelayConnection(string: saved) }
        reminders.registerCategories()
        reload()
    }

    func start() async {
        #if DEBUG
        // 模拟器测试用：xcrun simctl launch booted com.rain.daily.phone -dailyConnect <地址>
        if let url = UserDefaults.standard.string(forKey: "dailyConnect"), connection?.baseURL.absoluteString != url {
            connect(url)
        }
        #endif
        await configureSources()
        // 不等用户点通知授权，先同步
        Task {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "dailyConnect") != nil { return }  // 截图时不弹授权框
            #endif
            if await reminders.authorizationStatus() == .notDetermined {
                await reminders.requestAuthorization()
            }
            await refreshNotificationAccess()
        }
        await syncNow()
    }

    private func configureSources() async {
        await sync.unregister(sourceID: RelaySnapshotSource.id)
        await sync.unregister(sourceID: AgentRelaySource.id)
        await sync.unregister(sourceID: systemCalendar.sourceID)
        if let client {
            // 自己读本机日历时，不要 Mac 同步来的系统日历，免得重复
            await sync.register(RelaySnapshotSource(client: client, excludedKinds: usesLocalCalendar ? [.systemCalendar] : []))
            await sync.register(AgentRelaySource(client: client))
        }
        if usesLocalCalendar, SystemCalendarSource.access == .granted {
            await sync.register(systemCalendar)
        }
    }

    // MARK: - 连接

    /// 扫码打开的 `daily://relay?url=…`，或粘贴的地址。返回是否有效。
    @discardableResult
    func connect(_ text: String) -> Bool {
        guard let connection = RelayConnection(string: text) else { return false }
        Keychain.set(connection.baseURL.absoluteString, for: Self.relayAccount)
        self.connection = connection
        error = nil
        Task {
            await configureSources()
            await syncNow()
            setLive(true)
        }
        return true
    }

    func disconnect() {
        Keychain.set(nil, for: Self.relayAccount)
        connection = nil
        setLive(false)
        try? store.deleteItems(sourceID: RelaySnapshotSource.id)
        try? store.deleteItems(sourceID: AgentRelaySource.id)
        Task { await configureSources() }
        finish()
    }

    func handle(_ url: URL) {
        guard url.scheme == "daily" else { return }
        if url.host == "relay",
           let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
            connect(value)
        } else if url.host == "open" {
            let seconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "date" }?.value.flatMap(Double.init)
            startDate = calendar.startOfDay(for: seconds.map(Date.init(timeIntervalSince1970:)) ?? .now)
        }
    }

    /// App 在前台时保持实时推送连接；退到后台就断开。
    func setLive(_ on: Bool) {
        liveChannel?.stop()
        liveChannel = nil
        isLive = false
        guard on, let connection else { return }
        let channel = RelayLiveChannel(connection: connection) { [weak self] in
            Task { await self?.syncNow() }
        } onStateChange: { [weak self] live in
            self?.isLive = live
        }
        liveChannel = channel
        channel.start()
    }

    // MARK: - 同步

    private var syncRange: DateInterval {
        let today = calendar.startOfDay(for: .now)
        return DateInterval(start: calendar.date(byAdding: .day, value: -35, to: today)!,
                            end: calendar.date(byAdding: .day, value: 190, to: today)!)
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if let client { await flushParcelPicks(client) }
        let failures = await sync.syncAll(in: syncRange)
        if let failure = failures[RelaySnapshotSource.id] ?? failures[AgentRelaySource.id] {
            error = "同步失败：\(failure.localizedDescription)"
        } else if connection != nil {
            error = nil
            lastSync = .now
        }
        finish()
        scheduleBackgroundRefresh()
    }

    private func finish() {
        reload()
        WidgetCenter.shared.reloadAllTimelines()
        scheduleReminders()
    }

    func reload() {
        let now = Date.now
        var result: [DayAgenda] = []
        let all = (try? store.items(in: DateInterval(start: startDate, duration: 31 * 86400))) ?? []
        for offset in 0..<31 {
            let start = calendar.date(byAdding: .day, value: offset, to: startDate)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            // 全天日程的结束是次日零点（不含）；定时日程只算开始那天
            let items = all.filter { $0.isAllDay ? ($0.start < end && $0.effectiveEnd > start) : ($0.start >= start && $0.start < end) }
            if !items.isEmpty || calendar.isDate(start, inSameDayAs: now) || offset == 0 {
                result.append(DayAgenda(date: start, items: items))
            }
        }
        days = result
        pendingParcels = (try? store.pendingParcels(now: now)) ?? []

        // 不限于同步范围：本地存着的都显示，翻到多久以前都能看到当时同步过的日程
        var byDay: [Date: [CalendarItem]] = [:]
        let wide = DateInterval(start: calendar.date(byAdding: .year, value: -20, to: now)!,
                                end: calendar.date(byAdding: .year, value: 20, to: now)!)
        for item in (try? store.items(in: wide)) ?? [] {
            var day = calendar.startOfDay(for: item.start)
            // 全天日程的结束是次日零点（不含）；跨午夜的定时日程每天都画一段；单条最多展开 62 天
            let last = item.isAllDay ? item.effectiveEnd.addingTimeInterval(-1) : item.effectiveEnd
            var count = 0
            repeat {
                byDay[day, default: []].append(item)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                count += 1
            } while day <= last && count < 62
        }
        itemsByDay = byDay
    }

    func items(on day: Date) -> [CalendarItem] {
        // 全天的排在前面
        (itemsByDay[calendar.startOfDay(for: day)] ?? []).sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    // MARK: - 取件

    func markPicked(_ item: CalendarItem) {
        try? store.markParcelPickedLocally(id: item.id)
        reload()
        Task {
            await reminders.removeDelivered(itemID: item.id)
            await syncNow()
        }
    }

    private func flushParcelPicks(_ client: RelayClient) async {
        guard let ids = try? store.takeParcelPicks(), !ids.isEmpty else { return }
        var failed: [String] = []
        for id in ids {
            do { try await client.markDone(id: id) } catch { failed.append(id) }
        }
        try? store.requeueParcelPicks(failed)
    }

    // MARK: - 新建

    /// 以 iPhone 的身份写进中转服务，Mac 和 AI 都能看到（显示在「Agent / Bot 写入」里）。
    func addEvent(_ draft: EventDraft) async throws {
        guard let client else { throw RelayError.message("还没有连接 Mac 上的 Daily") }
        let end = draft.isAllDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: draft.end)) : draft.end
        try await client.addEvent(
            title: draft.title.trimmingCharacters(in: .whitespaces),
            start: RelayClient.timeString(draft.start, allDay: draft.isAllDay, calendar: calendar),
            end: end.map { RelayClient.timeString($0, allDay: draft.isAllDay, calendar: calendar) },
            allDay: draft.isAllDay,
            location: draft.location.trimmingCharacters(in: .whitespaces),
            notes: draft.notes.trimmingCharacters(in: .whitespacesAndNewlines))
        await syncNow()
    }

    // MARK: - 提醒

    func refreshNotificationAccess() async {
        notificationAccess = switch await reminders.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    func requestNotifications() async {
        await reminders.requestAuthorization()
        await refreshNotificationAccess()
        scheduleReminders()
    }

    func scheduleReminders() {
        reminderTask?.cancel()
        reminderTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshNotificationAccess()
            guard notificationAccess == .granted else { return }
            let now = Date.now
            let settings = Preferences.shared.reminders
            let upcoming = (try? store.items(in: DateInterval(start: now, duration: 62 * 86400))) ?? []
            let parcels = (try? store.pendingParcels(now: now)) ?? []
            await reminders.replaceScheduled(with: ReminderPlanner.scheduled(
                items: upcoming, pendingParcels: parcels, subscriptions: [], settings: settings, now: now,
                calendar: calendar, renewalsFromItems: true))
            var notified = Preferences.shared.notifiedParcelIDs
            let arrivals = ReminderPlanner.parcelArrivals(parcels, notified: Set(notified), settings: settings, now: now)
            notified += parcels.map(ReminderPlanner.arrivalKey).filter { !notified.contains($0) }
            Preferences.shared.notifiedParcelIDs = notified
            await reminders.deliver(arrivals)
        }
    }

    // MARK: - 后台刷新

    /// 让系统在后台不时唤醒 Daily 同步一次（时间由系统决定），保证提醒和小组件不过期。
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date.now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
