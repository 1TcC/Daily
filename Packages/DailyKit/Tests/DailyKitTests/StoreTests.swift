import Foundation
import Testing
@testable import DailyKit

private let shanghai: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return cal
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    shanghai.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func item(_ ext: String, _ title: String, _ start: Date, source: String = "feed") -> CalendarItem {
    CalendarItem(sourceKind: .course, sourceID: source, externalID: ext, title: title,
                 start: start, end: start.addingTimeInterval(3600))
}

@Suite struct ItemStoreTests {
    let week = DateInterval(start: date(2026, 10, 26), end: date(2026, 11, 2))

    @Test func saveAndQueryRoundTrip() throws {
        let store = try ItemStore.inMemory()
        var original = item("a", "数据结构", date(2026, 10, 29, 10))
        original.location = "实验楼 305"
        original.metadata = ["code": "6-2-1043"]
        try store.save(original)

        let loaded = try store.items(in: week)
        #expect(loaded == [original].map { var i = $0; i.updatedAt = loaded[0].updatedAt; return i })
        #expect(loaded[0].metadata["code"] == "6-2-1043")
    }

    @Test func queryFiltersByRangeAndStatus() throws {
        let store = try ItemStore.inMemory()
        try store.save(item("in", "本周", date(2026, 10, 29, 8)))
        try store.save(item("out", "下周", date(2026, 11, 3, 8)))
        var pending = item("p", "待确认", date(2026, 10, 30, 8))
        pending.status = .pending
        try store.save(pending)

        #expect(try store.items(in: week).map(\.title) == ["本周"])
        #expect(try store.items(in: week, statuses: [.confirmed, .pending]).map(\.title) == ["本周", "待确认"])
        #expect(try store.pendingItems().map(\.title) == ["待确认"])
    }

    @Test func pointEventsWithoutEndAreIncluded() throws {
        let store = try ItemStore.inMemory()
        var parcel = item("x", "快递待取件", date(2026, 10, 29, 16))
        parcel.end = nil
        try store.save(parcel)
        #expect(try store.items(in: week).count == 1)
    }

    @Test func snapshotUpdatesInsertsAndDeletes() throws {
        let store = try ItemStore.inMemory()
        try store.replaceSnapshot(sourceID: "feed", in: week, with: [
            item("a", "高数", date(2026, 10, 26, 8)),
            item("b", "英语", date(2026, 10, 27, 8)),
        ])
        let firstID = try #require(try store.items(in: week).first { $0.externalID == "a" }).id

        try store.replaceSnapshot(sourceID: "feed", in: week, with: [
            item("a", "高等数学", date(2026, 10, 26, 8)),
            item("c", "物理", date(2026, 10, 28, 8)),
        ])
        let items = try store.items(in: week)
        #expect(items.map(\.title) == ["高等数学", "物理"])
        #expect(items.first?.id == firstID)
    }

    @Test func snapshotKeepsDismissedAndOtherSources() throws {
        let store = try ItemStore.inMemory()
        try store.replaceSnapshot(sourceID: "feed", in: week, with: [item("a", "高数", date(2026, 10, 26, 8))])
        try store.save(item("z", "别的来源", date(2026, 10, 27, 8), source: "other"))
        let id = try #require(try store.items(in: week).first { $0.externalID == "a" }).id
        try store.setStatus(.dismissed, for: id)

        try store.replaceSnapshot(sourceID: "feed", in: week, with: [item("a", "高数", date(2026, 10, 26, 8))])
        #expect(try store.item(id: id)?.status == .dismissed)
        #expect(try store.items(in: week).map(\.title) == ["别的来源"])
    }

    @Test func snapshotOnlyTouchesItsRange() throws {
        let store = try ItemStore.inMemory()
        try store.save(item("old", "上周的课", date(2026, 10, 20, 8)))
        try store.replaceSnapshot(sourceID: "feed", in: week, with: [])
        let all = DateInterval(start: date(2026, 10, 1), end: date(2026, 12, 1))
        #expect(try store.items(in: all).map(\.title) == ["上周的课"])
    }

    @Test func persistsToDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("daily.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ItemStore(url: url).save(item("a", "高数", date(2026, 10, 26, 8)))
        #expect(try ItemStore(url: url).items(in: week).count == 1)
    }
}

@Suite struct SubscriptionTests {
    @Test func monthlyRenewalsClampToMonthEnd() {
        let sub = Subscription(name: "iCloud+", price: 21, cycle: .monthly, firstBillingDate: date(2026, 1, 31))
        let range = DateInterval(start: date(2026, 2, 1), end: date(2026, 5, 1))
        let days = sub.renewals(in: range, calendar: shanghai).map { shanghai.component(.day, from: $0) }
        #expect(days == [28, 31, 30])
    }

    @Test func yearlyAndInactive() {
        var sub = Subscription(name: "域名", price: 70, cycle: .yearly, firstBillingDate: date(2024, 11, 5))
        let range = DateInterval(start: date(2026, 1, 1), end: date(2027, 1, 1))
        #expect(sub.renewals(in: range, calendar: shanghai) == [date(2026, 11, 5)])
        sub.isActive = false
        #expect(sub.renewals(in: range, calendar: shanghai).isEmpty)
    }

    @Test func monthlyCost() {
        #expect(Subscription(name: "a", price: 120, cycle: .yearly, firstBillingDate: .now).monthlyCost == 10)
        #expect(Subscription(name: "b", price: 30, cycle: .quarterly, firstBillingDate: .now).monthlyCost == 10)
    }

    @Test func providerProducesAllDayItems() async throws {
        let store = try ItemStore.inMemory()
        try store.save(Subscription(name: "音乐会员", price: 15, cycle: .monthly, firstBillingDate: date(2026, 9, 6)))
        let range = DateInterval(start: date(2026, 10, 1), end: date(2026, 12, 1))
        let items = try await SubscriptionProvider(store: store).fetch(in: range)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.isAllDay && $0.sourceKind == .subscription })
        #expect(items.first?.title == "音乐会员 续费 ¥15")
    }
}

private struct StubProvider: SourceProvider {
    let sourceID: String
    let kind = SourceKind.agent
    let displayName = "stub"
    let result: Result<[CalendarItem], URLError>
    func fetch(in range: DateInterval) async throws -> [CalendarItem] { try result.get() }
}

@Suite struct SyncEngineTests {
    @Test func failingSourceDoesNotBlockOthers() async throws {
        let store = try ItemStore.inMemory()
        let engine = SyncEngine(store: store)
        let week = DateInterval(start: date(2026, 10, 26), end: date(2026, 11, 2))
        await engine.register(StubProvider(sourceID: "ok", result: .success([item("a", "比赛", date(2026, 10, 29, 19), source: "ok")])))
        await engine.register(StubProvider(sourceID: "bad", result: .failure(URLError(.notConnectedToInternet))))

        let failures = await engine.syncAll(in: week)
        #expect(Array(failures.keys) == ["bad"])
        #expect(try store.items(in: week).map(\.title) == ["比赛"])
        #expect(await engine.lastSynced["ok"] != nil)
    }
}

@Suite struct DemoDataTests {
    @Test func clearRemovesOnlyDemoData() throws {
        let store = try ItemStore.inMemory()
        try DemoData.seed(store)
        let real = CalendarItem(sourceKind: .systemCalendar, sourceID: "system-calendar", externalID: "r",
                                title: "真实日程", start: .now, end: .now.addingTimeInterval(3600))
        try store.save(real)
        try store.save(Subscription(name: "真实订阅", price: 30, cycle: .monthly, firstBillingDate: .now))
        // 早期版本写入的、没有标记的示例订阅也要能识别
        try store.save(Subscription(name: "iCloud+", price: 21, cycle: .monthly, firstBillingDate: .now))
        #expect(DemoData.hasDemoData(in: store))

        let removed = try DemoData.clear(from: store)
        #expect(removed > 0)
        #expect(!DemoData.hasDemoData(in: store))
        #expect(try store.itemCount(sourceID: "demo-", prefix: true) == 0)
        #expect(try store.pendingItems().isEmpty)
        #expect(try store.subscriptions().map(\.name) == ["真实订阅"])
        #expect(try store.item(id: real.id)?.title == "真实日程")
    }
}
