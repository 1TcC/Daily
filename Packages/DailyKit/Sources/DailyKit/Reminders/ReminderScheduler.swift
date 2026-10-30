import Foundation
import UserNotifications

/// 把 `ReminderPlanner` 算出的提醒同步到系统通知中心：多的撤掉、缺的补上、没变的不动。
/// 定时通知交给系统，Daily 没在运行时也会按时弹出。
public final class ReminderScheduler: Sendable {
    public static let pickedAction = "picked"
    static let prefix = "daily."

    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    /// 注册通知分类：取件通知上带「已取」按钮。
    public func registerCategories() {
        let picked = UNNotificationAction(identifier: Self.pickedAction, title: "已取", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: PlannedReminder.Category.parcel.rawValue, actions: [picked], intentIdentifiers: []),
            UNNotificationCategory(identifier: PlannedReminder.Category.travel.rawValue, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: PlannedReminder.Category.subscription.rawValue, actions: [], intentIdentifiers: []),
        ])
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 用新的定时提醒替换旧的。
    public func replaceScheduled(with planned: [PlannedReminder]) async {
        let wanted = Dictionary(planned.filter { $0.fireDate != nil }.map { (Self.prefix + $0.id, $0) }) { a, _ in a }
        let existing = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) })
        let stale = existing.subtracting(wanted.keys)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        for (id, reminder) in wanted where !existing.contains(id) {
            try? await center.add(request(id: id, reminder))
        }
    }

    /// 立即发出（取件码到了）。
    public func deliver(_ reminders: [PlannedReminder]) async {
        for reminder in reminders {
            try? await center.add(request(id: Self.prefix + reminder.id, reminder))
        }
    }

    /// 取件后撤掉这件快递已经显示的通知。
    public func removeDelivered(itemID: UUID) async {
        let ids = await center.deliveredNotifications()
            .filter { $0.request.content.userInfo["itemID"] as? String == itemID.uuidString }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    private func request(id: String, _ reminder: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.categoryIdentifier = reminder.category.rawValue
        content.threadIdentifier = reminder.category.rawValue
        if let itemID = reminder.itemID { content.userInfo = ["itemID": itemID.uuidString] }
        let trigger: UNNotificationTrigger? = reminder.fireDate.map { date in
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
