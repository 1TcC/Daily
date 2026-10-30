import AppIntents
import DailyKit
import Foundation

/// 小组件上的「已取」：本地先隐藏这件快递，再通知 App 去中转服务里删除（小组件不能联网）。
struct MarkParcelPickedIntent: AppIntent {
    static let title: LocalizedStringResource = "标记已取件"
    static let isDiscoverable = false

    @Parameter(title: "条目") var itemID: String

    init() {}

    init(itemID: UUID) {
        self.itemID = itemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: itemID) {
            try ItemStore(url: AppGroup.databaseURL).markParcelPickedLocally(id: id)
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(ParcelPick.darwinNotification as CFString), nil, nil, true)
        return .result()
    }
}
