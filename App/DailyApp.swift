import AppKit
import DailyKit
import DailyUI
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WidgetKit

/// App 级服务：共享存储、同步引擎、系统日历和主窗口状态。
@MainActor
final class AppServices {
    let store: ItemStore
    let sync: SyncEngine
    let model: CalendarModel
    let systemCalendar = SystemCalendarSource()
    private var syncedRange: DateInterval?
    private var calendarChangeTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var relaySource: AgentRelaySource?
    private var relayTimer: Timer?
    private var liveChannel: RelayLiveChannel?
    private var wakeObserver: NSObjectProtocol?
    private var lastSnapshotBody: Data?
    private var reminderTask: Task<Void, Never>?
    private var started = false
    let reminders = ReminderScheduler()
    private static let relayAccount = "relayConnection"

    init() {
        let store = (try? ItemStore(url: AppGroup.databaseURL)) ?? (try! ItemStore.inMemory())
        self.store = store
        self.sync = SyncEngine(store: store)
        self.model = CalendarModel(store: store)
        model.excludedCalendarIDs = Preferences.shared.excludedCalendarIDs
        model.courseSchedule = try? store.courseSchedule()
    }

    func start() async {
        guard !started else { return }
        started = true
        await sync.register(SubscriptionProvider(store: store))
        await sync.register(systemCalendar)
        await sync.register(CourseScheduleProvider(store: store))

        model.actions.requestCalendarAccess = { [weak self] in
            Task { await self?.requestCalendarAccess() }
        }
        model.actions.setCalendarIncluded = { [weak self] id, included in
            var excluded = Preferences.shared.excludedCalendarIDs
            if included { excluded.remove(id) } else { excluded.insert(id) }
            Preferences.shared.excludedCalendarIDs = excluded
            Task { await self?.syncSystemCalendar() }
        }
        model.actions.importCourseSchedule = { [weak self] schedule in
            guard let self else { return }
            try? store.saveCourseSchedule(schedule)
            model.courseSchedule = schedule
            Task {
                try? await self.sync.sync(sourceID: CourseScheduleProvider.id, in: self.syncedRange ?? self.syncWindow)
                self.finishSync()
            }
        }
        model.actions.visibleRangeChanged = { [weak self] interval in
            guard let self, let synced = syncedRange,
                  interval.start < synced.start || interval.end > synced.end else { return }
            Task { await self.syncNow() }
        }

        // 日历 App 里有增删改时 EventKit 会发通知，稍等合并连续变化后再同步。
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendarChangeTask?.cancel()
                self?.calendarChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await self?.syncSystemCalendar()
                }
            }
        }

        model.actions.syncRelay = { [weak self] in Task { await self?.syncRelay() } }
        model.actions.refresh = { [weak self] in
            // 手动刷新时快照也强制重新上传（例如中转服务升级后，让 iPhone 版拿到新字段）
            self?.lastSnapshotBody = nil
            Task { await self?.syncNow() }
        }
        model.actions.markParcelPicked = { [weak self] item in self?.markParcelPicked(item) }
        model.actions.itemsChanged = { [weak self] in self?.finishSync() }
        model.actions.subscriptionsChanged = { [weak self] in
            guard let self else { return }
            Task {
                try? await self.sync.sync(sourceID: SubscriptionProvider.id, in: self.syncedRange ?? self.syncWindow)
                self.finishSync()
            }
        }
        model.actions.remindersChanged = { [weak self] in self?.scheduleReminders() }
        model.actions.requestNotificationAccess = { [weak self] in
            Task {
                await self?.reminders.requestAuthorization()
                await self?.refreshNotificationAccess()
                self?.scheduleReminders()
            }
        }
        model.actions.sendTestNotification = { [weak self] in
            Task {
                await self?.reminders.deliver([PlannedReminder(
                    id: "test.\(Int(Date.now.timeIntervalSince1970))", category: .travel, fireDate: nil,
                    title: "Daily 提醒测试", body: "出行、取件码和订阅续费会像这样提醒你。")])
            }
        }
        model.actions.setLaunchAtLogin = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
        model.actions.connectRelay = { [weak self] text in
            guard let self, let connection = RelayConnection(string: text) else { return false }
            Keychain.set(connection.baseURL.absoluteString, for: Self.relayAccount)
            Task { await self.connectRelay(connection, syncNow: true) }
            return true
        }
        model.actions.setRelayPublicHost = { [weak self] host in self?.setRelayPublicHost(host) }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        reminders.registerCategories()
        observeWidgetPicks()
        model.actions.disconnectRelay = { [weak self] in Task { await self?.disconnectRelay() } }
        if let saved = Keychain.string(for: Self.relayAccount), let connection = RelayConnection(string: saved) {
            await connectRelay(connection, syncNow: false)
        }

        // 第一次打开时请求通知权限（只用于出行、取件码和订阅提醒）；不等用户点，先同步
        Task {
            if await reminders.authorizationStatus() == .notDetermined {
                await reminders.requestAuthorization()
            }
            await refreshNotificationAccess()
            scheduleReminders()
        }

        if SystemCalendarSource.access == .notDetermined {
            await requestCalendarAccess()
        } else {
            refreshCalendarList()
            await syncNow()
        }
    }

    // MARK: - 取件

    func markParcelPicked(_ item: CalendarItem) {
        // 先在本地隐藏，界面立即更新；中转服务里的条目放进队列，由同步时删除
        try? store.markParcelPickedLocally(id: item.id)
        model.reload()
        Task { await reminders.removeDelivered(itemID: item.id) }
        if relaySource != nil {
            Task { await syncRelay() }
        } else {
            finishSync()
        }
    }

    /// 小组件上点了「已取」后会发一个跨进程通知，收到就马上同步。
    private func observeWidgetPicks() {
        AppServices.current = self
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    AppServices.current?.model.reload()
                    await AppServices.current?.syncRelay()
                }
            },
            ParcelPick.darwinNotification as CFString, nil, .deliverImmediately)
    }

    static weak var current: AppServices?

    /// 把小组件和本机点过「已取」的快递告诉中转服务；失败的留到下次。
    private func flushParcelPicks(_ client: RelayClient) async {
        guard let ids = try? store.takeParcelPicks(), !ids.isEmpty else { return }
        var failed: [String] = []
        for id in ids {
            do { try await client.markDone(id: id) } catch { failed.append(id) }
        }
        try? store.requeueParcelPicks(failed)
        if !failed.isEmpty { model.relay?.error = "标记已取件失败，稍后重试" }
    }

    // MARK: - 提醒

    private func refreshNotificationAccess() async {
        model.notificationAccess = switch await reminders.authorizationStatus() {
        case .authorized, .provisional: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    /// 重新计算出行、取件和续费提醒；连续调用时合并成一次。
    func scheduleReminders() {
        reminderTask?.cancel()
        reminderTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refreshNotificationAccess()
            guard model.notificationAccess == .granted else { return }
            let now = Date.now
            let settings = Preferences.shared.reminders
            let upcoming = (try? store.items(in: DateInterval(start: now, duration: 15 * 86400))) ?? []
            let parcels = (try? store.pendingParcels(now: now)) ?? []
            let subs = (try? store.subscriptions()) ?? []
            await reminders.replaceScheduled(with: ReminderPlanner.scheduled(
                items: upcoming, pendingParcels: parcels, subscriptions: subs, settings: settings, now: now))

            var notified = Preferences.shared.notifiedParcelIDs
            let arrivals = ReminderPlanner.parcelArrivals(parcels, notified: Set(notified), settings: settings, now: now)
            // 关掉「收到时通知」期间到的快递也记下来，重新打开后不会补发一堆
            notified += parcels.map(ReminderPlanner.arrivalKey).filter { !notified.contains($0) }
            Preferences.shared.notifiedParcelIDs = notified
            await reminders.deliver(arrivals)
        }
    }

    // MARK: - 登录时打开

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Daily: 登录项设置失败 \(error)")
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setRelayPublicHost(_ host: String?) {
        Preferences.shared.relayPublicHost = host
        if let saved = Keychain.string(for: Self.relayAccount), let connection = RelayConnection(string: saved) {
            Task { await connectRelay(connection, syncNow: false) }
        }
    }

    // MARK: - Grok 中转

    /// `daily://relay?url=<https://worker/密钥>` 写入连接；`daily://relay?disconnect=1` 断开。
    /// 小组件：`daily://open?date=<秒>` 跳到那一天，`daily://new` 新建日程。
    func handle(_ url: URL) {
        guard url.scheme == "daily" else { return }
        if url.host == "open" {
            let seconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "date" }?.value.flatMap(Double.init)
            model.searchText = ""
            model.anchorDate = seconds.map(Date.init(timeIntervalSince1970:)) ?? .now
            return
        }
        if url.host == "subscriptions" {
            model.showingSubscriptions = true
            return
        }
        if url.host == "new" {
            model.newEvent()
            return
        }
        guard url.host == "relay",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        if let host = items.first(where: { $0.name == "public-host" })?.value {
            // 设置手机直连域名：daily://relay?public-host=daily.0netc.com（空值表示取消）
            setRelayPublicHost(host.isEmpty ? nil : host)
        } else if let what = items.first(where: { $0.name == "copy" })?.value, let relay = model.relay {
            // 生成快捷指令时由脚本调用：把只写的短信地址（或只读订阅地址）放进剪贴板
            let url: URL? = switch what {
            case "sms-ingest": relaySource?.client.connection.smsIngestURL
            case "feed": relay.calendarFeedURL
            default: nil
            }
            if let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        } else if items.contains(where: { $0.name == "disconnect" }) {
            Task { await disconnectRelay() }
        } else if let value = items.first(where: { $0.name == "url" })?.value,
                  let connection = RelayConnection(string: value) {
            Keychain.set(connection.baseURL.absoluteString, for: Self.relayAccount)
            Task { await connectRelay(connection, syncNow: true) }
        }
    }

    private func connectRelay(_ connection: RelayConnection, syncNow: Bool) async {
        var connection = connection
        connection.publicHost = Preferences.shared.relayPublicHost
        let source = AgentRelaySource(client: RelayClient(connection: connection))
        relaySource = source
        lastSnapshotBody = nil
        await sync.register(source)
        model.relay = RelayStatus(mcpURL: connection.mcpURL, calendarFeedURL: connection.calendarFeedURL)
        model.relay?.phoneAppURL = connection.phoneAppURL

        // 实时推送：Grok 一改日程就收到通知并拉取。
        liveChannel?.stop()
        let channel = RelayLiveChannel(connection: connection) { [weak self] in
            Task { await self?.syncRelay() }
        } onStateChange: { [weak self] live in
            self?.model.relay?.isLive = live
        }
        liveChannel = channel
        channel.start()

        // 兜底：每 2 分钟拉一次；Mac 从睡眠唤醒时重连并同步。
        relayTimer?.invalidate()
        relayTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncRelay() }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.liveChannel?.restart()
                    await self?.syncRelay()
                }
            }
        }
        if syncNow { await syncRelay() }
    }

    func syncRelay() async {
        guard let source = relaySource else { return }
        await flushParcelPicks(source.client)
        do {
            try await sync.sync(sourceID: source.sourceID, in: syncedRange ?? syncWindow)
            model.relay?.lastSync = .now
            model.relay?.error = nil
        } catch {
            model.relay?.error = "Grok 同步失败：\(error.localizedDescription)"
        }
        finishSync()
    }

    private func disconnectRelay() async {
        Keychain.set(nil, for: Self.relayAccount)
        liveChannel?.stop()
        liveChannel = nil
        relayTimer?.invalidate()
        relayTimer = nil
        if let source = relaySource { await sync.unregister(sourceID: source.sourceID) }
        relaySource = nil
        try? store.deleteItems(sourceID: AgentRelaySource.id)
        model.relay = nil
        finishSync()
    }

    /// 把今天前 7 天到后 60 天的日程（来自中转服务的除外）上传给中转服务，内容没变就跳过。
    private func uploadSnapshotIfNeeded() {
        guard let client = relaySource?.client else { return }
        let calendar = model.calendar
        let today = calendar.startOfDay(for: .now)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: today)!,
                                 end: calendar.date(byAdding: .day, value: 60, to: today)!)
        // 中转服务自己的条目（AI 和短信写入的）不回传，否则 Grok 和 iPhone 订阅里会出现两份
        guard let items = try? store.items(in: range).filter({ $0.sourceID != AgentRelaySource.id }),
              let body = try? RelayClient.snapshotBody(items, calendar: calendar),
              body != lastSnapshotBody else { return }
        Task {
            do {
                try await client.uploadSnapshot(body: body)
                lastSnapshotBody = body
            } catch {
                model.relay?.error = "日程快照上传失败：\(error.localizedDescription)"
            }
        }
    }

    func requestCalendarAccess() async {
        await systemCalendar.requestAccess()
        refreshCalendarList()
        await syncNow()
    }

    private func refreshCalendarList() {
        model.calendarAccess = SystemCalendarSource.access
        model.systemCalendars = systemCalendar.calendars()
    }

    /// 同步当前显示日期前 1 个月到后 6 个月。
    private var syncWindow: DateInterval {
        let calendar = model.calendar
        let anchor = calendar.startOfDay(for: model.anchorDate)
        let start = calendar.date(byAdding: .month, value: -1, to: anchor)!
        return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 7, to: start)!)
    }

    func syncNow() async {
        model.isSyncing = true
        defer { model.isSyncing = false }
        let range = syncWindow
        let failures = await sync.syncAll(in: range)
        syncedRange = range
        if relaySource != nil {
            if let error = failures[AgentRelaySource.id] {
                model.relay?.error = "Grok 同步失败：\(error.localizedDescription)"
            } else {
                model.relay?.lastSync = .now
                model.relay?.error = nil
            }
        }
        finishSync()
    }

    private func syncSystemCalendar() async {
        refreshCalendarList()
        try? await sync.sync(sourceID: systemCalendar.sourceID, in: syncedRange ?? syncWindow)
        finishSync()
    }

    private func finishSync() {
        model.lastSync = .now
        model.reload()
        WidgetCenter.shared.reloadAllTimelines()
        uploadSnapshotIfNeeded()
        scheduleReminders()
    }

    func clearDemoData() {
        try? DemoData.clear(from: store)
        model.reload()
        // 重新同步，按剩下的真实订阅重新生成续费条目。
        Task { await syncNow() }
    }

    func loadDemoData() {
        try? DemoData.seed(store)
        model.reload()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// 是否是登录 Mac 时被自动打开的：这时只在后台运行，不弹出主窗口。
enum LaunchContext {
    static let isLoginLaunch: Bool = {
        guard SMAppService.mainApp.status == .enabled else { return false }
        // 登录项由系统在开机登录后几分钟内启动；用户自己打开时开机早就超过这个时间了
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return ProcessInfo.processInfo.systemUptime < 180
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    lazy var services = AppServices()
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            UNUserNotificationCenter.current().delegate = self
            if LaunchContext.isLoginLaunch && Preferences.shared.showMenuBarIcon {
                NSApp.setActivationPolicy(.accessory)
            }
            // 关掉主窗口后只留菜单栏图标，Dock 里不显示
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { note in
                nonisolated(unsafe) let object = note.object
                MainActor.assumeIsolated {
                    guard let window = object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true,
                          Preferences.shared.showMenuBarIcon else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            let services = services
            Task { await services.start() }
        }
    }

    /// 关掉主窗口后继续在后台同步、发提醒。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Preferences.shared.showMenuBarIcon
    }

    // App 在前台时也弹出提醒
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 取件通知上点「已取」。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let itemID = (response.notification.request.content.userInfo["itemID"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            guard action == ReminderScheduler.pickedAction, let itemID,
                  let item = try? services.store.item(id: itemID) else { return }
            services.markParcelPicked(item)
        }
    }
}

/// 菜单栏面板：「打开 Daily」时恢复 Dock 图标并把主窗口拿到前面。
private struct MenuBarContent: View {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(model: services.model) {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

@main
struct DailyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // 只有一个主窗口：不要标签页
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    private var services: AppServices { delegate.services }

    var body: some Scene {
        // Window（而不是 WindowGroup）：整个 App 只有一个主窗口，不能新建第二个
        Window("Daily", id: "main") {
            MainWindowView(model: services.model)
                .frame(minWidth: 960, minHeight: 600)
                .onOpenURL { services.handle($0) }
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(LaunchContext.isLoginLaunch ? .suppressed : .presented)
        .commands {
            EventCommands(model: services.model)
            TextSizeCommands(model: services.model)
            CommandMenu("数据") {
                Button("立即同步") { Task { await services.syncNow() } }
                Button("管理订阅…") { services.model.showingSubscriptions = true }
                Divider()
                Button("载入示例数据") { services.loadDemoData() }
                Button("清除示例数据") { services.clearDemoData() }
            }
        }

        Settings {
            SettingsView(model: services.model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { services.model.showMenuBarIcon },
            set: { services.model.showMenuBarIcon = $0 }
        )) {
            MenuBarContent(services: services)
        } label: {
            Image(systemName: "calendar")
        }
        .menuBarExtraStyle(.window)
    }
}
