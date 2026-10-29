import DailyKit
import DailyUI
import SwiftUI
import WidgetKit

/// App 级服务：共享存储、同步引擎和主窗口状态。
@MainActor
final class AppServices {
    let store: ItemStore
    let sync: SyncEngine
    let model: CalendarModel

    init() {
        let store = (try? ItemStore(url: AppGroup.databaseURL)) ?? (try! ItemStore.inMemory())
        self.store = store
        self.sync = SyncEngine(store: store)
        self.model = CalendarModel(store: store)
    }

    func start() async {
        await sync.register(SubscriptionProvider(store: store))
        await syncNow()
    }

    func syncNow() async {
        let calendar = model.calendar
        let start = calendar.date(byAdding: .month, value: -1, to: calendar.startOfDay(for: .now))!
        let range = DateInterval(start: start, end: calendar.date(byAdding: .month, value: 6, to: start)!)
        await sync.syncAll(in: range)
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
