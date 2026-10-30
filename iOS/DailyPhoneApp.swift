import DailyKit
import DailyUI
import SwiftUI
import UserNotifications

@main
struct DailyPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(services: delegate.services)
                .onOpenURL { delegate.services.handle($0) }
                .task { await delegate.services.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            let services = delegate.services
            // 回到前台时同步并接上实时推送；进后台就断开
            if phase == .active {
                services.setLive(true)
                Task { await services.syncNow() }
            } else if phase == .background {
                services.setLive(false)
            }
        }
        .backgroundTask(.appRefresh(PhoneServices.refreshTaskID)) {
            await delegate.services.syncNow()
        }
    }
}

/// 通知：前台也弹出；取件通知上的「已取」。
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor lazy var services = PhoneServices()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let itemID = (response.notification.request.content.userInfo["itemID"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            guard action == ReminderScheduler.pickedAction, let itemID,
                  let item = try? services.store.item(id: itemID) else { return }
            services.markPicked(item)
        }
    }
}

struct PhoneRootView: View {
    let services: PhoneServices

    var body: some View {
        if services.connection == nil {
            ConnectView(services: services)
        } else {
            PhoneCalendarView(services: services)
        }
    }
}
