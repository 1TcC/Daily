import AppKit
import DailyKit
import DailyUI
import EventKit
import SwiftUI
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
        model.actions.refresh = { [weak self] in Task { await self?.syncNow() } }
        model.actions.disconnectRelay = { [weak self] in Task { await self?.disconnectRelay() } }
        if let saved = Keychain.string(for: Self.relayAccount), let connection = RelayConnection(string: saved) {
            await connectRelay(connection, syncNow: false)
        }

        if SystemCalendarSource.access == .notDetermined {
            await requestCalendarAccess()
        } else {
            refreshCalendarList()
            await syncNow()
        }
    }

    // MARK: - Grok 中转

    /// `daily://relay?url=<https://worker/密钥>` 写入连接；`daily://relay?disconnect=1` 断开。
    func handle(_ url: URL) {
        guard url.scheme == "daily", url.host == "relay",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        if let what = items.first(where: { $0.name == "copy" })?.value, let relay = model.relay {
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
        let source = AgentRelaySource(client: RelayClient(connection: connection))
        relaySource = source
        lastSnapshotBody = nil
        await sync.register(source)
        model.relay = RelayStatus(mcpURL: connection.mcpURL, calendarFeedURL: connection.calendarFeedURL)

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

    /// 把今天前 7 天到后 60 天的日程（Grok 自己写的除外）上传给中转服务，内容没变就跳过。
    private func uploadSnapshotIfNeeded() {
        guard let client = relaySource?.client else { return }
        let calendar = model.calendar
        let today = calendar.startOfDay(for: .now)
        let range = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: today)!,
                                 end: calendar.date(byAdding: .day, value: 60, to: today)!)
        guard let items = try? store.items(in: range).filter({ $0.sourceKind != .agent }),
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

@main
struct DailyApp: App {
    // App 结构体只创建一次，服务对象直接持有即可。
    private let services = AppServices()

    var body: some Scene {
        WindowGroup("Daily") {
            MainWindowView(model: services.model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await services.start() }
                .onOpenURL { services.handle($0) }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            TextSizeCommands(model: services.model)
            CommandMenu("数据") {
                Button("立即同步") { Task { await services.syncNow() } }
                Divider()
                Button("载入示例数据") { services.loadDemoData() }
                Button("清除示例数据") { services.clearDemoData() }
            }
        }
    }
}
