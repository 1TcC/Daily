import Foundation

/// 把本地录入的订阅按周期展开成全天的「续费」条目。
public struct SubscriptionProvider: SourceProvider {
    public static let id = "subscriptions"
    public let sourceID = SubscriptionProvider.id
    public let kind = SourceKind.subscription
    public let displayName = SourceKind.subscription.displayName
    private let store: ItemStore

    public init(store: ItemStore) {
        self.store = store
    }

    public func fetch(in range: DateInterval) async throws -> [CalendarItem] {
        try items(in: range)
    }

    public func items(in range: DateInterval) throws -> [CalendarItem] {
        let calendar = Calendar.current
        return try store.subscriptions().flatMap { sub in
            sub.renewals(in: range, calendar: calendar).map { date in
                return CalendarItem(
                    sourceKind: .subscription,
                    sourceID: sourceID,
                    externalID: "\(sub.id.uuidString)#\(Int(date.timeIntervalSince1970))",
                    title: "\(sub.name) 续费 \(sub.priceText)",
                    start: date,
                    end: calendar.date(byAdding: .day, value: 1, to: date),
                    isAllDay: true,
                    metadata: ["subscriptionID": sub.id.uuidString, "price": "\(sub.price)", "currency": sub.currency]
                )
            }
        }
    }
}
