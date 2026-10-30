import Foundation

/// 提醒设置。Daily 只提醒三类事：出行、取件码、订阅续费。
public struct ReminderSettings: Codable, Hashable, Sendable {
    /// 出行：出发前多少分钟提醒（0 表示不提醒）。
    public var travelLeadMinutes = 60
    /// 出行：前一天晚上提醒一次（时刻见 `travelEveningMinute`）。
    public var travelEveningBefore = true
    /// 前一天晚上提醒的时刻，从零点起的分钟数。
    public var travelEveningMinute = 21 * 60

    /// 取件码：收到短信后立刻通知。
    public var parcelOnArrival = true
    /// 取件码：每天定时提醒还没取的快递。
    public var parcelDaily = true
    public var parcelDailyMinute = 18 * 60

    /// 订阅：续费前提醒。
    public var subscriptionEnabled = true
    /// 提前几天提醒（0 表示当天）。
    public var subscriptionLeadDays = 1
    public var subscriptionMinute = 9 * 60

    public init() {}

    public var travelEnabled: Bool { travelLeadMinutes > 0 || travelEveningBefore }
}

public extension Int {
    /// 把「从零点起的分钟数」写成「21:00」。
    var clockText: String { String(format: "%d:%02d", self / 60, self % 60) }
}
