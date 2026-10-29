import Foundation
import Testing
@testable import DailyKit

@Suite struct SystemCalendarMappingTests {
    let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    func date(_ d: Int, _ h: Int = 0, _ m: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m, second: s))!
    }

    let info = SystemCalendarInfo(id: "cal-1", title: "工作", accountName: "iCloud", colorHex: "#FF9500")

    @Test func timedEventKeepsCalendarColorAndIdentity() {
        let record = SystemEventRecord(calendarItemID: "evt", calendarID: "cal-1", title: "  组会 ",
                                       location: "", notes: "带电脑", start: date(29, 14), end: date(29, 15), isAllDay: false)
        let item = SystemCalendarSource.item(from: record, calendar: info, calendar: calendar)
        #expect(item.sourceKind == .systemCalendar)
        #expect(item.sourceID == "system-calendar")
        #expect(item.title == "组会")
        #expect(item.location == nil)
        #expect(item.notes == "带电脑")
        #expect(item.metadata["color"] == "#FF9500")
        #expect(item.metadata["calendarTitle"] == "工作")
        #expect(item.externalID == "evt#\(Int(date(29, 14).timeIntervalSince1970))")
    }

    @Test func recurringOccurrencesGetDistinctIDs() {
        let a = SystemEventRecord(calendarItemID: "evt", calendarID: "cal-1", title: "课", start: date(28, 8), end: date(28, 9), isAllDay: false)
        var b = a
        b.start = date(29, 8)
        b.end = date(29, 9)
        #expect(SystemCalendarSource.item(from: a, calendar: info).externalID
                != SystemCalendarSource.item(from: b, calendar: info).externalID)
    }

    @Test func allDayEndIsNormalizedToNextMidnight() {
        let record = SystemEventRecord(calendarItemID: "h", calendarID: "cal-1", title: "国庆",
                                       start: date(1), end: date(3, 23, 59, 59), isAllDay: true)
        let item = SystemCalendarSource.item(from: record, calendar: nil, calendar: calendar)
        #expect(item.isAllDay)
        #expect(item.end == date(4))
        #expect(item.metadata["color"] == nil)
    }

    @Test func untitledEvent() {
        let record = SystemEventRecord(calendarItemID: "x", calendarID: "c", title: nil, start: date(1, 9), end: date(1, 10), isAllDay: false)
        #expect(SystemCalendarSource.item(from: record, calendar: nil).title == "（无标题）")
    }

    @Test func hexConversion() {
        #expect(SystemCalendarSource.hex(red: 1, green: 0.5843, blue: 0) == "#FF9500")
        #expect(SystemCalendarSource.hex(red: -0.1, green: 1.2, blue: 0) == "#00FF00")
    }

    @Test func excludedCalendarsPersist() {
        let suite = "daily-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let prefs = Preferences(suiteName: suite)
        #expect(prefs.excludedCalendarIDs.isEmpty)
        prefs.excludedCalendarIDs = ["b", "a"]
        #expect(Preferences(suiteName: suite).excludedCalendarIDs == ["a", "b"])
    }
}
