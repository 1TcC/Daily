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

    init() {
        let store = (try? ItemStore(url: AppGroup.databaseURL)) ?? (try! ItemStore.inMemory())
        self.store = store
        self.sync = SyncEngine(store: store)
        self.model = CalendarModel(store: store)
        model.excludedCalendarIDs = Preferences.shared.excludedCalendarIDs
    }

    func start() async {
        await sync.register(SubscriptionProvider(store: store))
        await sync.register(systemCalendar)

        model.actions.requestCalendarAccess = { [weak self] in
            Task { await self?.requestCalendarAccess() }
        }
        model.actions.setCalendarIncluded = { [weak self] id, included in
            var excluded = Preferences.shared.excludedCalendarIDs
            if included { excluded.remove(id) } else { excluded.insert(id) }
            Preferences.shared.excludedCalendarIDs = excluded
            Task { await self?.syncSystemCalendar() }
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

        if SystemCalendarSource.access == .notDetermined {
            await requestCalendarAccess()
        } else {
            refreshCalendarList()
            await syncNow()
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
        let range = syncWindow
        await sync.syncAll(in: range)
        syncedRange = range
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
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandMenu("数据") {
                Button("立即同步") { Task { await services.syncNow() } }
                    .keyboardShortcut("r")
                Divider()
                Button("载入示例数据") { services.loadDemoData() }
            }
        }
    }
}
