import Foundation

/// 开发预览和截图用的示例数据，围绕给定日期所在的一周生成。
public enum DemoData {
    /// 示例订阅写在 notes 里的标记，用来和真实订阅区分。
    static let marker = "示例数据"
    /// 早期版本写入的示例订阅没有标记，按名称和价格识别。
    private static let legacySubscriptions: Set<String> = ["iCloud+#21", "音乐会员#15", "AI 助手#140"]

    /// 清除示例数据：示例日程（来源 demo-*）、示例订阅及其续费条目。真实来源的数据不受影响。
    /// 返回删除的日程条数。
    @discardableResult
    public static func clear(from store: ItemStore) throws -> Int {
        var removed = try store.deleteItems(sourceID: "demo-", prefix: true)
        let demoSubs = try store.subscriptions().filter {
            $0.notes == marker || legacySubscriptions.contains("\($0.name)#\($0.price)")
        }
        for sub in demoSubs { try store.deleteSubscription(id: sub.id) }
        if !demoSubs.isEmpty {
            // 续费条目由订阅生成，删掉后由下一次同步按剩下的真实订阅重新生成。
            removed += try store.deleteItems(sourceID: SubscriptionProvider.id)
        }
        return removed
    }

    public static func hasDemoData(in store: ItemStore) -> Bool {
        let demoItems = (try? store.itemCount(sourceID: "demo-", prefix: true)) ?? 0
        let demoSubs = (try? store.subscriptions())?.contains {
            $0.notes == marker || legacySubscriptions.contains("\($0.name)#\($0.price)")
        } ?? false
        return demoItems > 0 || demoSubs
    }

    public static func seed(_ store: ItemStore, around now: Date = .now, calendar: Calendar = .mondayFirst) throws {
        let weekStart = calendar.startOfWeek(for: now)
        func at(_ day: Int, _ hour: Double) -> Date {
            let d = calendar.date(byAdding: .day, value: day, to: weekStart)!
            return d.addingTimeInterval(hour * 3600)
        }
        func add(_ kind: SourceKind, _ day: Int, _ start: Double, _ end: Double?, _ title: String,
                 location: String? = nil, allDay: Bool = false, status: ItemStatus = .confirmed,
                 metadata: [String: String] = [:]) throws {
            try store.save(CalendarItem(
                sourceKind: kind, sourceID: "demo-\(kind.rawValue)",
                externalID: "\(title)#\(day)#\(start)", title: title, location: location,
                start: allDay ? at(day, 0) : at(day, start),
                end: allDay ? at(day + 1, 0) : end.map { at(day, $0) },
                isAllDay: allDay, status: status, metadata: metadata
            ))
        }

        let courses: [(Int, Double, String, String)] = [
            (0, 8, "高等数学", "教三 201"), (0, 10, "大学英语", "外语楼 412"),
            (1, 8, "线性代数", "教二 108"), (1, 14, "体育", "东操场"),
            (2, 8, "高等数学", "教三 201"), (2, 10, "数据结构", "实验楼 305"),
            (3, 8, "大学物理", "教一 302"), (3, 10, "数据结构", "实验楼 305"),
            (4, 8, "线性代数", "教二 108"), (4, 10, "大学英语", "外语楼 412"),
        ]
        for (day, start, title, room) in courses {
            try add(.course, day, start, start + 1 + 40.0 / 60, title, location: room)
        }
        try add(.systemCalendar, 0, 19, 20.5, "健身", location: "校体育馆")
        try add(.message, 2, 15, 16, "导师组会", location: "腾讯会议")
        try add(.parcel, 3, 12 + 10.0 / 60, nil, "外卖送达")
        try add(.systemCalendar, 3, 14, 15.5, "社团例会", location: "学生活动中心")
        try add(.parcel, 3, 16, nil, "快递待取件", location: "驿站", metadata: ["pickupCode": "6-2-1043"])
        try add(.agent, 3, 19 + 35.0 / 60, 21 + 35.0 / 60, "编程比赛", location: "线上")
        try add(.systemCalendar, 4, 15, 16, "小组讨论", location: "图书馆 3F")
        try add(.travel, 5, 8.25, 12 + 43.0 / 60, "G1234 上海虹桥 → 北京南",
                location: "05车 12F", metadata: ["gate": "B12"])
        try add(.systemCalendar, 6, 14, 16, "看展", location: "美术馆")
        try add(.message, 3, 0, nil, "数据库作业截止", allDay: true)
        try add(.message, 9, 23 + 59.0 / 60, nil, "数据库实验报告截止", status: .pending,
                metadata: ["from": "邮件 · 教务处"])
        try add(.message, 16, 9, 11, "高等数学 期中考试", location: "教三 101", status: .pending,
                metadata: ["from": "微信 · 班级群"])

        let firstBilling = calendar.date(byAdding: .month, value: -3, to: at(6, 0))!
        try store.save(Subscription(name: "iCloud+", price: 21, cycle: .monthly, firstBillingDate: firstBilling, notes: marker))
        try store.save(Subscription(name: "音乐会员", price: 15, cycle: .monthly,
                                    firstBillingDate: calendar.date(byAdding: .day, value: -1, to: firstBilling)!, notes: marker))
        try store.save(Subscription(name: "AI 助手", price: 140, cycle: .monthly,
                                    firstBillingDate: calendar.date(byAdding: .day, value: 18, to: firstBilling)!, notes: marker))
        let range = DateInterval(start: calendar.date(byAdding: .month, value: -1, to: weekStart)!,
                                 end: calendar.date(byAdding: .month, value: 2, to: weekStart)!)
        let renewals = try SubscriptionProvider(store: store).items(in: range)
        try store.replaceSnapshot(sourceID: "subscriptions", in: range, with: renewals)
    }
}

public extension Calendar {
    /// 中国习惯：周一为一周第一天。
    static var mondayFirst: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    func startOfWeek(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps).map(startOfDay(for:)) ?? startOfDay(for: date)
    }
}
