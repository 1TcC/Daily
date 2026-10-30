import Foundation
import Testing
@testable import DailyKit

private let shanghai: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    cal.firstWeekday = 2
    return cal
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    shanghai.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func trip(_ start: Date, title: String = "G1234 上海虹桥") -> CalendarItem {
    CalendarItem(sourceKind: .travel, sourceID: "agent-relay", externalID: "t", title: title, location: "上海虹桥站",
                 start: start, metadata: ["train": "G1234", "seat": "5车12号", "gate": "B12"])
}

private func parcel(_ code: String, _ received: Date, relayID: String) -> CalendarItem {
    CalendarItem(sourceKind: .parcel, sourceID: "agent-relay", externalID: relayID, title: "取件 \(code)",
                 start: received, metadata: ["pickupCode": code, "station": "菜鸟驿站", "relayID": relayID])
}

@Suite struct ReminderPlannerTests {
    let now = date(2026, 10, 30, 10)

    @Test func travelGetsLeadAndEveningReminders() {
        let item = trip(date(2026, 10, 31, 8, 15))
        let plan = ReminderPlanner.scheduled(items: [item], pendingParcels: [], subscriptions: [],
                                             settings: ReminderSettings(), now: now, calendar: shanghai)
        #expect(plan.map(\.fireDate) == [date(2026, 10, 30, 21), date(2026, 10, 31, 7, 15)])
        #expect(plan[0].title == "明天出行：G1234 上海虹桥")
        #expect(plan[1].title == "1 小时后发车：G1234 上海虹桥")
        #expect(plan[1].body == "10月31日 8:15 发车 · 上海虹桥站 · 5车12号 · 检票口 B12")
    }

    @Test func pastAndDisabledTravelRemindersAreSkipped() {
        // 离出发不到 1 小时：出发前提醒已经错过；当天出发也没有前一晚提醒
        let soon = trip(date(2026, 10, 30, 10, 30))
        var settings = ReminderSettings()
        #expect(ReminderPlanner.scheduled(items: [soon], pendingParcels: [], subscriptions: [],
                                          settings: settings, now: now, calendar: shanghai).isEmpty)
        settings.travelLeadMinutes = 0
        settings.travelEveningBefore = false
        let later = trip(date(2026, 11, 2, 9))
        #expect(ReminderPlanner.scheduled(items: [later], pendingParcels: [], subscriptions: [],
                                          settings: settings, now: now, calendar: shanghai).isEmpty)
    }

    @Test func otherKindsNeverRemind() {
        let course = CalendarItem(sourceKind: .course, sourceID: "course", title: "高等数学", start: date(2026, 10, 30, 14))
        #expect(ReminderPlanner.scheduled(items: [course], pendingParcels: [], subscriptions: [],
                                          settings: ReminderSettings(), now: now, calendar: shanghai).isEmpty)
    }

    @Test func dailyParcelReminderListsWaitingParcels() {
        let parcels = [parcel("6-2-1043", date(2026, 10, 30, 9), relayID: "a"),
                       parcel("3-1-0021", date(2026, 10, 29, 15), relayID: "b")]
        let plan = ReminderPlanner.scheduled(items: [], pendingParcels: parcels, subscriptions: [],
                                             settings: ReminderSettings(), now: now, calendar: shanghai)
        #expect(plan.count == 1)
        #expect(plan[0].fireDate == date(2026, 10, 30, 18))
        #expect(plan[0].title == "还有 2 个快递没取")
        #expect(plan[0].body == "6-2-1043  菜鸟驿站\n3-1-0021  菜鸟驿站")
        // 过了今天的提醒时间就排到明天
        let evening = ReminderPlanner.scheduled(items: [], pendingParcels: parcels, subscriptions: [],
                                                settings: ReminderSettings(), now: date(2026, 10, 30, 19), calendar: shanghai)
        #expect(evening.first?.fireDate == date(2026, 10, 31, 18))
    }

    @Test func parcelArrivalNotifiesOnce() {
        let fresh = parcel("6-2-1043", date(2026, 10, 30, 9, 50), relayID: "a")
        let old = parcel("1-1-1", date(2026, 10, 28, 9), relayID: "b")
        let first = ReminderPlanner.parcelArrivals([fresh, old], notified: [], settings: ReminderSettings(), now: now)
        #expect(first.map(\.title) == ["取件码 6-2-1043"])
        #expect(first[0].fireDate == nil)
        #expect(ReminderPlanner.parcelArrivals([fresh], notified: ["a"], settings: ReminderSettings(), now: now).isEmpty)
        var off = ReminderSettings()
        off.parcelOnArrival = false
        #expect(ReminderPlanner.parcelArrivals([fresh], notified: [], settings: off, now: now).isEmpty)
    }

    @Test func subscriptionRemindsBeforeRenewal() {
        let sub = Subscription(name: "iCloud+", price: 21, cycle: .monthly, firstBillingDate: date(2026, 8, 3))
        let plan = ReminderPlanner.scheduled(items: [], pendingParcels: [], subscriptions: [sub],
                                             settings: ReminderSettings(), now: now, calendar: shanghai)
        #expect(plan.first?.fireDate == date(2026, 11, 2, 9))
        #expect(plan.first?.title == "iCloud+ 明天续费")
        #expect(plan.first?.body == "¥21 · 每月 · 11月3日扣费")
        var paused = sub
        paused.isActive = false
        #expect(ReminderPlanner.scheduled(items: [], pendingParcels: [], subscriptions: [paused],
                                          settings: ReminderSettings(), now: now, calendar: shanghai).isEmpty)
    }

    @Test func idsChangeWhenTimeChanges() {
        let a = ReminderPlanner.scheduled(items: [trip(date(2026, 11, 2, 9))], pendingParcels: [], subscriptions: [],
                                          settings: ReminderSettings(), now: now, calendar: shanghai)
        let b = ReminderPlanner.scheduled(items: [trip(date(2026, 11, 2, 10))], pendingParcels: [], subscriptions: [],
                                          settings: ReminderSettings(), now: now, calendar: shanghai)
        #expect(Set(a.map(\.id)).isDisjoint(with: b.map(\.id)))
    }
}

@Suite struct StoreSearchAndPickTests {
    @Test func searchMatchesTitleLocationAndMetadata() throws {
        let store = try ItemStore.inMemory()
        try store.save(CalendarItem(sourceKind: .manual, sourceID: "manual", title: "组会", location: "腾讯会议",
                                    start: date(2026, 11, 2, 15)))
        try store.save(parcel("6-2-1043", date(2026, 10, 30, 9), relayID: "a"))
        try store.save(CalendarItem(sourceKind: .manual, sourceID: "manual", title: "100%完成", start: date(2026, 11, 3)))
        #expect(try store.search("组会").map(\.title) == ["组会"])
        #expect(try store.search("腾讯").map(\.title) == ["组会"])
        #expect(try store.search("1043").map(\.title) == ["取件 6-2-1043"])
        #expect(try store.search("%").map(\.title) == ["100%完成"])
        #expect(try store.search("组会 腾讯").count == 1)
        #expect(try store.search("组会 驿站").isEmpty)
        #expect(try store.search("  ").isEmpty)
    }

    @Test func widgetPickHidesParcelAndQueuesRelayID() throws {
        let store = try ItemStore.inMemory()
        let item = parcel("6-2-1043", date(2026, 10, 30, 9), relayID: "relay-1")
        try store.save(item)
        #expect(try store.pendingParcels(now: date(2026, 10, 30, 10)).count == 1)
        try store.markParcelPickedLocally(id: item.id)
        #expect(try store.pendingParcels(now: date(2026, 10, 30, 10)).isEmpty)
        #expect(try store.takeParcelPicks() == ["relay-1"])
        #expect(try store.takeParcelPicks().isEmpty)
        try store.requeueParcelPicks(["relay-1"])
        #expect(try store.takeParcelPicks() == ["relay-1"])
    }

    @Test func pickedParcelStaysHiddenAfterRelaySync() throws {
        let store = try ItemStore.inMemory()
        let range = DateInterval(start: date(2026, 10, 1), end: date(2026, 12, 1))
        let item = parcel("6-2-1043", date(2026, 10, 30, 9), relayID: "relay-1")
        try store.replaceSnapshot(sourceID: "agent-relay", in: range, with: [item])
        let saved = try #require(try store.pendingParcels(now: date(2026, 10, 30, 10)).first)
        try store.markParcelPickedLocally(id: saved.id)
        // 中转服务还没删掉它之前的又一次同步
        try store.replaceSnapshot(sourceID: "agent-relay", in: range, with: [item])
        #expect(try store.pendingParcels(now: date(2026, 10, 30, 10)).isEmpty)
    }
}
