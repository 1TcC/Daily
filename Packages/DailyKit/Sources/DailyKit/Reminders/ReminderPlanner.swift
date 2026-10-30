import Foundation

/// 一条要发的系统通知。`id` 由内容决定：时间或内容变了 id 就变，旧通知会被撤掉换成新的。
public struct PlannedReminder: Hashable, Sendable {
    public enum Category: String, Sendable {
        case travel, parcel, subscription
    }

    public var id: String
    public var category: Category
    /// nil 表示立即发出。
    public var fireDate: Date?
    public var title: String
    public var body: String
    /// 对应的日程条目（点「已取」时用）。
    public var itemID: UUID?

    public init(id: String, category: Category, fireDate: Date?, title: String, body: String, itemID: UUID? = nil) {
        self.id = id
        self.category = category
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.itemID = itemID
    }
}

/// 根据日程、快递和订阅算出接下来要发的提醒；不碰系统通知，方便测试。
public enum ReminderPlanner {
    /// macOS 每个 App 最多挂 64 条待发通知，留些余量。
    public static let maxPending = 60

    /// 定时提醒：出行（出发前、前一晚）、每天的未取件提醒、订阅续费。按时间排序，最多 `maxPending` 条。
    /// iPhone 版没有订阅列表，`renewalsFromItems` 为 true 时改用 `items` 里的续费条目（Mac 同步过来的）。
    public static func scheduled(items: [CalendarItem], pendingParcels: [CalendarItem], subscriptions: [Subscription],
                                 settings: ReminderSettings, now: Date, calendar: Calendar = .mondayFirst,
                                 renewalsFromItems: Bool = false) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        let horizon = now.addingTimeInterval(14 * 86400)

        for trip in items where trip.sourceKind == .travel && !trip.isAllDay && trip.start > now && trip.start < horizon {
            let stamp = Int(trip.start.timeIntervalSince1970)
            let detail = tripDetail(trip, calendar: calendar)
            if settings.travelLeadMinutes > 0 {
                let fire = trip.start.addingTimeInterval(-Double(settings.travelLeadMinutes * 60))
                if fire > now {
                    result.append(PlannedReminder(
                        id: "travel.\(trip.id.uuidString).lead.\(stamp).\(settings.travelLeadMinutes)",
                        category: .travel, fireDate: fire,
                        title: "\(leadText(settings.travelLeadMinutes))后\(departWord(trip))：\(trip.title)",
                        body: detail, itemID: trip.id))
                }
            }
            if settings.travelEveningBefore,
               let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: trip.start)) {
                let fire = dayBefore.addingTimeInterval(Double(settings.travelEveningMinute * 60))
                // 出发太早（离提醒不到 3 小时）就不必再提前一晚提醒
                if fire > now, trip.start.timeIntervalSince(fire) > 3 * 3600 {
                    result.append(PlannedReminder(
                        id: "travel.\(trip.id.uuidString).eve.\(stamp).\(settings.travelEveningMinute)",
                        category: .travel, fireDate: fire,
                        title: "明天出行：\(trip.title)", body: detail, itemID: trip.id))
                }
            }
        }

        if settings.parcelDaily, !pendingParcels.isEmpty,
           let fire = nextOccurrence(ofMinute: settings.parcelDailyMinute, after: now, calendar: calendar) {
            // 到提醒时刻才收到的快递不算，那时刚通知过
            let waiting = pendingParcels.filter { $0.start < fire.addingTimeInterval(-30 * 60) }
            if !waiting.isEmpty {
                let lines = waiting.prefix(4).map { [$0.metadata["pickupCode"], $0.metadata["station"]].compactMap { $0 }.joined(separator: "  ") }
                let more = waiting.count > 4 ? "\n等 \(waiting.count) 个" : ""
                result.append(PlannedReminder(
                    id: "parcel.daily.\(Int(fire.timeIntervalSince1970)).\(waiting.map(\.id.uuidString).sorted().joined().hashValueStable)",
                    category: .parcel, fireDate: fire,
                    title: "还有 \(waiting.count) 个快递没取", body: lines.joined(separator: "\n") + more,
                    itemID: waiting.count == 1 ? waiting[0].id : nil))
            }
        }

        if settings.subscriptionEnabled && renewalsFromItems {
            for item in items where item.sourceKind == .subscription && item.isAllDay {
                guard let day = calendar.date(byAdding: .day, value: -settings.subscriptionLeadDays, to: item.start) else { continue }
                let fire = day.addingTimeInterval(Double(settings.subscriptionMinute * 60))
                guard fire > now else { continue }
                // 续费条目的标题是「iCloud+ 续费 ¥21」
                let parts = item.title.components(separatedBy: " 续费 ")
                result.append(PlannedReminder(
                    id: "subscription.\(item.title.hashValueStable).\(Int(item.start.timeIntervalSince1970)).\(settings.subscriptionLeadDays)",
                    category: .subscription, fireDate: fire,
                    title: "\(parts[0]) \(whenText(settings.subscriptionLeadDays))续费",
                    body: [parts.count > 1 ? parts[1] : nil, "\(dayText(item.start, calendar: calendar))扣费"]
                        .compactMap { $0 }.joined(separator: " · ")))
            }
        }

        if settings.subscriptionEnabled && !renewalsFromItems {
            let range = DateInterval(start: calendar.startOfDay(for: now), duration: 62 * 86400)
            for sub in subscriptions where sub.isActive {
                for renewal in sub.renewals(in: range, calendar: calendar) {
                    guard let day = calendar.date(byAdding: .day, value: -settings.subscriptionLeadDays, to: renewal) else { continue }
                    let fire = day.addingTimeInterval(Double(settings.subscriptionMinute * 60))
                    guard fire > now else { continue }
                    let when = whenText(settings.subscriptionLeadDays)
                    result.append(PlannedReminder(
                        id: "subscription.\(sub.id.uuidString).\(Int(renewal.timeIntervalSince1970)).\(settings.subscriptionLeadDays).\(sub.priceText)",
                        category: .subscription, fireDate: fire,
                        title: "\(sub.name) \(when)续费",
                        body: "\(sub.priceText) · \(sub.cycle.displayName) · \(dayText(renewal, calendar: calendar))扣费"))
                }
            }
        }

        return Array(result.sorted { ($0.fireDate ?? now) < ($1.fireDate ?? now) }.prefix(maxPending))
    }

    /// 刚收到的取件码：最近 12 小时内收到、还没通知过的，立即通知。
    public static func parcelArrivals(_ parcels: [CalendarItem], notified: Set<String>, settings: ReminderSettings,
                                      now: Date) -> [PlannedReminder] {
        guard settings.parcelOnArrival else { return [] }
        return parcels
            .filter { $0.isParcelWithCode && $0.start > now.addingTimeInterval(-12 * 3600) && $0.start <= now.addingTimeInterval(300) }
            .filter { !notified.contains(arrivalKey($0)) }
            .sorted { $0.start < $1.start }
            .map { parcel in
                PlannedReminder(
                    id: "parcel.arrival.\(arrivalKey(parcel))", category: .parcel, fireDate: nil,
                    title: "取件码 \(parcel.metadata["pickupCode"] ?? "")",
                    body: [parcel.metadata["station"] ?? parcel.location, parcel.metadata["carrier"]].compactMap { $0 }
                        .joined(separator: " · "),
                    itemID: parcel.id)
            }
    }

    /// 判断取件码是否通知过用的键：中转服务的 ID（同步后不变）或条目 ID。
    public static func arrivalKey(_ parcel: CalendarItem) -> String {
        parcel.metadata["relayID"] ?? parcel.externalID ?? parcel.id.uuidString
    }

    // MARK: - 文案

    static func whenText(_ leadDays: Int) -> String {
        switch leadDays {
        case 0: "今天"
        case 1: "明天"
        case 2: "后天"
        default: "\(leadDays) 天后"
        }
    }

    static func leadText(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        if minutes > 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }

    static func departWord(_ trip: CalendarItem) -> String {
        trip.metadata["flight"] != nil ? "起飞" : trip.metadata["train"] != nil ? "发车" : "出发"
    }

    /// 「明天 8:15 发车 · 上海虹桥站 · 5车12号 · 检票口 B12」
    static func tripDetail(_ trip: CalendarItem, calendar: Calendar) -> String {
        [
            "\(dayText(trip.start, calendar: calendar)) \(clock(trip.start, calendar: calendar)) \(departWord(trip))",
            trip.location,
            trip.metadata["seat"],
            trip.metadata["gate"].map { "检票口 \($0)" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func nextOccurrence(ofMinute minute: Int, after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now).addingTimeInterval(Double(minute * 60))
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}

private extension String {
    /// 跨进程稳定的短哈希（Swift 的 hashValue 每次启动都不同）。
    var hashValueStable: String {
        var hash: UInt64 = 1469598103934665603
        for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 36)
    }
}
