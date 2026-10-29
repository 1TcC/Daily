import Foundation
import Testing
@testable import DailyKit

@Suite("ICSParser")
struct ICSParserTests {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let utc = TimeZone(identifier: "UTC")!

    /// 在指定时区构造日期。
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0,
                     tz: TimeZone = shanghai) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    static let wide = DateInterval(start: date(2020, 1, 1), end: date(2030, 1, 1))

    static func calendar(_ body: String, lf: Bool = false) -> String {
        let text = "BEGIN:VCALENDAR\nVERSION:2.0\n\(body)\nEND:VCALENDAR\n"
        return lf ? text : text.replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func parse(_ body: String, in range: DateInterval = wide) throws -> [ICSEvent] {
        try ICSParser.parse(calendar(body), expandingIn: range)
    }

    static func event(_ lines: String...) -> String {
        "BEGIN:VEVENT\n" + lines.joined(separator: "\n") + "\nEND:VEVENT"
    }

    // MARK: - 基础

    @Test func notACalendar() {
        #expect(throws: ICSParserError.notACalendar) {
            try ICSParser.parse("BEGIN:VEVENT\nSUMMARY:x\nEND:VEVENT", expandingIn: Self.wide)
        }
        #expect(throws: ICSParserError.notACalendar) {
            try ICSParser.parse("", expandingIn: Self.wide)
        }
    }

    @Test func foldingAndUnescaping() throws {
        let body = Self.event(
            "UID:u1",
            "SUMMARY:Hello\\, World\\; a\\\\b",
            "DESCRIPTION:line one\\nline two \\Nline three and a very long text that is fol",
            " ded across",
            "\t lines",
            "LOCATION:Room 1\\, Building 2",
            "DTSTART:20261029T080000Z",
            "DTEND:20261029T090000Z")
        for lf in [false, true] {
            let events = try ICSParser.parse(Self.calendar(body, lf: lf), expandingIn: Self.wide)
            #expect(events.count == 1)
            let e = events[0]
            #expect(e.summary == "Hello, World; a\\b")
            #expect(e.description == "line one\nline two \nline three and a very long text that is folded across lines")
            #expect(e.location == "Room 1, Building 2")
        }
    }

    @Test func foldedMultibyteText() throws {
        let events = try Self.parse(Self.event("UID:u", "SUMMARY:高等数学\\,", " 第一节", "DTSTART:20261029T080000Z"))
        #expect(events[0].summary == "高等数学,第一节")
    }

    // MARK: - 日期形式

    @Test func allDayLocalTimeZone() throws {
        let local = Calendar.current
        let events = try Self.parse(Self.event("UID:a", "SUMMARY:Holiday", "DTSTART;VALUE=DATE:20261029"))
        #expect(events.count == 1)
        let start = local.date(from: DateComponents(year: 2026, month: 10, day: 29))!
        #expect(events[0].isAllDay)
        #expect(events[0].start == start)
        #expect(events[0].end == local.date(byAdding: .day, value: 1, to: start))
    }

    @Test func allDayWithDTEND() throws {
        let local = Calendar.current
        let events = try Self.parse(Self.event("UID:a", "DTSTART;VALUE=DATE:20261001", "DTEND;VALUE=DATE:20261008"))
        #expect(events[0].start == local.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(events[0].end == local.date(from: DateComponents(year: 2026, month: 10, day: 8)))
    }

    @Test func utcTZIDAndFloating() throws {
        let events = try Self.parse([
            Self.event("UID:utc", "DTSTART:20261029T080000Z", "DTEND:20261029T090000Z"),
            Self.event("UID:tz", "DTSTART;TZID=Asia/Shanghai:20261029T080000", "DTEND;TZID=Asia/Shanghai:20261029T093000"),
            Self.event("UID:float", "DTSTART:20261029T080000"),
            Self.event("UID:bad", "DTSTART;TZID=Not/AZone:20261029T080000"),
        ].joined(separator: "\n"))
        let byUID = Dictionary(uniqueKeysWithValues: events.map { ($0.uid, $0) })
        let local = TimeZone.current
        #expect(byUID["utc"]?.start == Self.date(2026, 10, 29, 8, tz: Self.utc))
        #expect(byUID["utc"]?.end == Self.date(2026, 10, 29, 9, tz: Self.utc))
        #expect(byUID["tz"]?.start == Self.date(2026, 10, 29, 8))
        #expect(byUID["tz"]?.end == Self.date(2026, 10, 29, 9, 30))
        #expect(byUID["float"]?.start == Self.date(2026, 10, 29, 8, tz: local))
        #expect(byUID["float"]?.end == nil)
        #expect(byUID["bad"]?.start == Self.date(2026, 10, 29, 8, tz: local))
        #expect(byUID["tz"]?.isAllDay == false)
    }

    @Test func durationInsteadOfDTEND() throws {
        let events = try Self.parse(Self.event("UID:d", "DTSTART;TZID=Asia/Shanghai:20261029T080000", "DURATION:PT1H30M"))
        #expect(events[0].end == Self.date(2026, 10, 29, 9, 30))
    }

    // MARK: - 重复

    @Test func weeklyByDayWithCount() throws {
        let events = try Self.parse(Self.event(
            "UID:w", "DTSTART;TZID=Asia/Shanghai:20261026T080000", "DTEND;TZID=Asia/Shanghai:20261026T094000",
            "RRULE:FREQ=WEEKLY;COUNT=5;BYDAY=MO,WE,FR"))
        // 10/26 周一 -> 周一 周三 周五 周一 周三
        #expect(events.map(\.start) == [
            Self.date(2026, 10, 26, 8), Self.date(2026, 10, 28, 8), Self.date(2026, 10, 30, 8),
            Self.date(2026, 11, 2, 8), Self.date(2026, 11, 4, 8),
        ])
        #expect(events.allSatisfy { $0.end == $0.start.addingTimeInterval(100 * 60) })
    }

    @Test func countIgnoresRange() throws {
        // COUNT 从 DTSTART 开始计数，不受查询范围影响
        let body = Self.event("UID:c", "DTSTART;TZID=Asia/Shanghai:20261001T080000", "RRULE:FREQ=DAILY;COUNT=10")
        let range = DateInterval(start: Self.date(2026, 10, 8), end: Self.date(2026, 10, 31))
        let events = try Self.parse(body, in: range)
        #expect(events.map(\.start) == [Self.date(2026, 10, 8, 8), Self.date(2026, 10, 9, 8), Self.date(2026, 10, 10, 8)])
    }

    @Test func untilUTCAndDate() throws {
        let utcUntil = try Self.parse(Self.event(
            "UID:u", "DTSTART;TZID=Asia/Shanghai:20261001T080000",
            "RRULE:FREQ=WEEKLY;UNTIL=20261015T000000Z;BYDAY=TH"))
        // 10/1, 10/8 (10/15 08:00 CST = 00:00Z 当天, 含边界)
        #expect(utcUntil.map(\.start) == [Self.date(2026, 10, 1, 8), Self.date(2026, 10, 8, 8), Self.date(2026, 10, 15, 8)])

        let dateUntil = try Self.parse(Self.event(
            "UID:u", "DTSTART;TZID=Asia/Shanghai:20261001T080000",
            "RRULE:FREQ=WEEKLY;UNTIL=20261014;BYDAY=TH"))
        #expect(dateUntil.map(\.start) == [Self.date(2026, 10, 1, 8), Self.date(2026, 10, 8, 8)])

        let sameDay = try Self.parse(Self.event(
            "UID:u", "DTSTART;TZID=Asia/Shanghai:20261001T080000", "RRULE:FREQ=DAILY;UNTIL=20261003"))
        #expect(sameDay.count == 3)
    }

    @Test func chineseCourseSchedule() throws {
        let events = try Self.parse(Self.event(
            "UID:course-1", "SUMMARY:高等数学", "LOCATION:教学楼A101",
            "DTSTART;TZID=Asia/Shanghai:20260910T081000", "DTEND;TZID=Asia/Shanghai:20260910T095500",
            "RRULE:FREQ=WEEKLY;UNTIL=20261231T160000Z;BYDAY=TH"))
        #expect(events.count == 17)
        #expect(events.first?.start == Self.date(2026, 9, 10, 8, 10))
        #expect(events.last?.start == Self.date(2026, 12, 31, 8, 10))
        #expect(events.allSatisfy { $0.summary == "高等数学" && $0.location == "教学楼A101" })
    }

    @Test func intervalTwo() throws {
        let events = try Self.parse(Self.event(
            "UID:i", "DTSTART;TZID=Asia/Shanghai:20261026T080000", "RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=3"))
        #expect(events.map(\.start) == [Self.date(2026, 10, 26, 8), Self.date(2026, 11, 9, 8), Self.date(2026, 11, 23, 8)])

        let daily = try Self.parse(Self.event(
            "UID:i", "DTSTART;TZID=Asia/Shanghai:20261026T080000", "RRULE:FREQ=DAILY;INTERVAL=3;COUNT=3"))
        #expect(daily.map(\.start) == [Self.date(2026, 10, 26, 8), Self.date(2026, 10, 29, 8), Self.date(2026, 11, 1, 8)])
    }

    @Test func exdateLinesAndLists() throws {
        let events = try Self.parse(Self.event(
            "UID:e", "DTSTART;TZID=Asia/Shanghai:20261026T080000", "RRULE:FREQ=DAILY;COUNT=7",
            "EXDATE;TZID=Asia/Shanghai:20261027T080000",
            "EXDATE;TZID=Asia/Shanghai:20261028T080000,20261030T080000",
            "EXDATE:20261101T000000Z"))  // 20261101 00:00Z = 08:00 CST
        #expect(events.map(\.start) == [Self.date(2026, 10, 26, 8), Self.date(2026, 10, 29, 8), Self.date(2026, 10, 31, 8)])
    }

    @Test func recurrenceIDOverride() throws {
        let body = [
            Self.event("UID:r", "SUMMARY:Class", "DTSTART;TZID=Asia/Shanghai:20261026T080000",
                       "DTEND;TZID=Asia/Shanghai:20261026T090000", "RRULE:FREQ=DAILY;COUNT=3"),
            Self.event("UID:r", "SUMMARY:Class (moved)", "RECURRENCE-ID;TZID=Asia/Shanghai:20261027T080000",
                       "DTSTART;TZID=Asia/Shanghai:20261027T140000", "DTEND;TZID=Asia/Shanghai:20261027T153000"),
        ].joined(separator: "\n")
        let events = try Self.parse(body)
        #expect(events.map(\.start) == [Self.date(2026, 10, 26, 8), Self.date(2026, 10, 27, 14), Self.date(2026, 10, 28, 8)])
        #expect(events.map(\.summary) == ["Class", "Class (moved)", "Class"])
        #expect(events[1].end == Self.date(2026, 10, 27, 15, 30))

        // 覆盖移出范围后，原位置不再出现
        let range = DateInterval(start: Self.date(2026, 10, 27), end: Self.date(2026, 10, 27, 12))
        #expect(try Self.parse(body, in: range).isEmpty)
    }

    @Test func cancelledSkipped() throws {
        let body = [
            Self.event("UID:x", "SUMMARY:Gone", "STATUS:CANCELLED", "DTSTART:20261029T080000Z"),
            Self.event("UID:y", "SUMMARY:Kept", "STATUS:CONFIRMED", "DTSTART:20261029T090000Z"),
            Self.event("UID:z", "DTSTART:20261026T000000Z", "RRULE:FREQ=DAILY;COUNT=3"),
            Self.event("UID:z", "RECURRENCE-ID:20261027T000000Z", "STATUS:CANCELLED", "DTSTART:20261027T000000Z"),
        ].joined(separator: "\n")
        let events = try Self.parse(body)
        #expect(events.filter { $0.uid == "x" }.isEmpty)
        #expect(events.contains { $0.uid == "y" })
        #expect(events.filter { $0.uid == "z" }.count == 2)
    }

    @Test func valarmDoesNotLeak() throws {
        let body = """
        BEGIN:VTIMEZONE
        TZID:Asia/Shanghai
        BEGIN:STANDARD
        DTSTART:19700101T000000
        TZOFFSETFROM:+0800
        TZOFFSETTO:+0800
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VTODO
        UID:todo
        SUMMARY:A todo
        DTSTART:20261029T000000Z
        END:VTODO
        BEGIN:VEVENT
        UID:ev
        SUMMARY:Real
        DTSTART:20261029T080000Z
        BEGIN:VALARM
        ACTION:DISPLAY
        SUMMARY:Alarm summary
        DESCRIPTION:Alarm description
        TRIGGER:-PT10M
        DTSTART:19990101T000000Z
        END:VALARM
        LOCATION:Here
        END:VEVENT
        """
        let events = try Self.parse(body)
        #expect(events.count == 1)
        #expect(events[0].summary == "Real")
        #expect(events[0].description == nil)
        #expect(events[0].location == "Here")
        #expect(events[0].start == Self.date(2026, 10, 29, 8, tz: Self.utc))
    }

    @Test func monthlyAndYearlyRules() throws {
        func starts(_ rule: String, _ dtstart: String, count: Int) throws -> [Date] {
            try Self.parse(Self.event("UID:m", "DTSTART;TZID=Asia/Shanghai:\(dtstart)", "RRULE:\(rule);COUNT=\(count)")).map(\.start)
        }
        #expect(try starts("FREQ=MONTHLY;BYDAY=2TU", "20261013T100000", count: 3)
                == [Self.date(2026, 10, 13, 10), Self.date(2026, 11, 10, 10), Self.date(2026, 12, 8, 10)])
        #expect(try starts("FREQ=MONTHLY;BYDAY=-1FR", "20261030T100000", count: 3)
                == [Self.date(2026, 10, 30, 10), Self.date(2026, 11, 27, 10), Self.date(2026, 12, 25, 10)])
        // 31 日在无 31 日的月份被跳过
        #expect(try starts("FREQ=MONTHLY;BYMONTHDAY=31", "20261031T100000", count: 3)
                == [Self.date(2026, 10, 31, 10), Self.date(2026, 12, 31, 10), Self.date(2027, 1, 31, 10)])
        #expect(try starts("FREQ=MONTHLY;BYMONTHDAY=-1", "20261031T100000", count: 3)
                == [Self.date(2026, 10, 31, 10), Self.date(2026, 11, 30, 10), Self.date(2026, 12, 31, 10)])
        #expect(try starts("FREQ=MONTHLY;INTERVAL=2", "20261015T100000", count: 3)
                == [Self.date(2026, 10, 15, 10), Self.date(2026, 12, 15, 10), Self.date(2027, 2, 15, 10)])
        #expect(try starts("FREQ=YEARLY", "20261029T100000", count: 3)
                == [Self.date(2026, 10, 29, 10), Self.date(2027, 10, 29, 10), Self.date(2028, 10, 29, 10)])
        #expect(try starts("FREQ=YEARLY;BYMONTH=3,9;BYMONTHDAY=1", "20260301T100000", count: 3)
                == [Self.date(2026, 3, 1, 10), Self.date(2026, 9, 1, 10), Self.date(2027, 3, 1, 10)])
    }

    @Test func wallClockPreservedAcrossDST() throws {
        // 2026-03-08 美东进入夏令时
        let events = try Self.parse(Self.event(
            "UID:dst", "DTSTART;TZID=America/New_York:20260302T090000", "DTEND;TZID=America/New_York:20260302T100000",
            "RRULE:FREQ=WEEKLY;COUNT=3"))
        let ny = Self.newYork
        #expect(events.map(\.start) == [
            Self.date(2026, 3, 2, 9, tz: ny), Self.date(2026, 3, 9, 9, tz: ny), Self.date(2026, 3, 16, 9, tz: ny),
        ])
        #expect(events[1].start.timeIntervalSince(events[0].start) == 7 * 86400 - 3600)
        #expect(events.allSatisfy { $0.end == $0.start.addingTimeInterval(3600) })
    }

    @Test func allDayRecurrence() throws {
        let local = Calendar.current
        let events = try Self.parse(Self.event("UID:ad", "DTSTART;VALUE=DATE:20261001", "RRULE:FREQ=YEARLY;COUNT=2"))
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.isAllDay })
        #expect(events[1].start == local.date(from: DateComponents(year: 2027, month: 10, day: 1)))
        #expect(events[1].end == local.date(from: DateComponents(year: 2027, month: 10, day: 2)))
    }

    // MARK: - 范围与排序

    @Test func rangeFiltering() throws {
        let body = [
            Self.event("UID:before", "DTSTART:20260101T000000Z", "DTEND:20260101T010000Z"),
            Self.event("UID:inside", "DTSTART:20261029T080000Z", "DTEND:20261029T090000Z"),
            Self.event("UID:spanning", "DTSTART:20261028T000000Z", "DTEND:20261030T000000Z"),
            Self.event("UID:endsAtStart", "DTSTART:20261029T000000Z", "DTEND:20261029T020000Z"),
            Self.event("UID:startsAtEnd", "DTSTART:20261030T000000Z", "DTEND:20261030T010000Z"),
            Self.event("UID:after", "DTSTART:20270101T000000Z"),
        ].joined(separator: "\n")
        let range = DateInterval(start: Self.date(2026, 10, 29, 2, tz: Self.utc), end: Self.date(2026, 10, 30, tz: Self.utc))
        let events = try Self.parse(body, in: range)
        // endsAtStart 的结束时间恰为 range.start 之后 0 秒也不算（02:00Z == range.start，算重叠：end >= start）
        #expect(events.map(\.uid) == ["spanning", "endsAtStart", "inside"])
    }

    @Test func recurringRangeAndOrdering() throws {
        let body = [
            Self.event("UID:b", "DTSTART;TZID=Asia/Shanghai:20200105T200000", "RRULE:FREQ=WEEKLY"),  // 起点很早，无 COUNT/UNTIL
            Self.event("UID:a", "DTSTART:20261104T000000Z"),
        ].joined(separator: "\n")
        let range = DateInterval(start: Self.date(2026, 11, 1), end: Self.date(2026, 11, 15))
        let events = try Self.parse(body, in: range)
        // 2020-01-05 是周日；之后每周日 20:00
        #expect(events.map(\.start) == [
            Self.date(2026, 11, 1, 20), Self.date(2026, 11, 4, 0, tz: Self.utc), Self.date(2026, 11, 8, 20),
        ])
        #expect(events.map(\.start) == events.map(\.start).sorted())
    }

    @Test func longEventOverlapsRangeFromEarlierOccurrence() throws {
        // 每天 22:00 开始、持续 12 小时，范围起点之前开始的实例应被包含
        let body = Self.event("UID:n", "DTSTART;TZID=Asia/Shanghai:20260101T220000", "DTEND;TZID=Asia/Shanghai:20260102T100000",
                              "RRULE:FREQ=DAILY")
        let range = DateInterval(start: Self.date(2026, 10, 29, 6), end: Self.date(2026, 10, 29, 12))
        let events = try Self.parse(body, in: range)
        #expect(events.map(\.start) == [Self.date(2026, 10, 28, 22)])
    }

    @Test func safetyCapTerminates() throws {
        let body = Self.event("UID:inf", "DTSTART;TZID=Asia/Shanghai:20260101T080000", "RRULE:FREQ=DAILY")
        let huge = DateInterval(start: Self.date(2026, 1, 1), end: .distantFuture)
        let events = try Self.parse(body, in: huge)
        #expect(events.count == 5000)
    }
}
