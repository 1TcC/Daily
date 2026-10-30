import Foundation
import Testing
@testable import DailyKit

@Suite struct RelayTests {
    let calendar: Calendar = {
        var cal = Calendar.mondayFirst
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    func date(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    @Test func connectionParsing() {
        let c = RelayConnection(string: " https://daily-relay.example.workers.dev/abc123/mcp/ ")
        #expect(c?.baseURL.absoluteString == "https://daily-relay.example.workers.dev/abc123")
        #expect(c?.mcpURL.absoluteString == "https://daily-relay.example.workers.dev/abc123/mcp")
        #expect(RelayConnection(string: "http://example.com/abc") == nil)
        #expect(RelayConnection(string: "https://example.com") == nil)
        #expect(RelayConnection(string: "http://localhost:8787/testsecret") != nil)
    }

    @Test func agentEventMapping() {
        let event = RelayAgentEvent(id: "u1", title: "编程比赛", start: "2026-11-03T22:35:00+08:00",
                                    end: "2026-11-04T00:35:00+08:00", allDay: false, location: "线上", notes: "Div.2")
        let item = AgentRelaySource.item(from: event, calendar: calendar)
        #expect(item?.sourceKind == .agent)
        #expect(item?.externalID == "u1")
        #expect(item?.start == date(11, 3, 22, 35))
        #expect(item?.end == date(11, 4, 0, 35))
        #expect(item?.location == "线上")
    }

    @Test func allDayAndDeleted() {
        let allDay = RelayAgentEvent(id: "u2", title: "运动会", start: "2026-11-07")
        let item = AgentRelaySource.item(from: allDay, calendar: calendar)
        #expect(item?.isAllDay == true)
        #expect(item?.start == date(11, 7))
        #expect(item?.end == date(11, 8))

        var deleted = allDay
        deleted.deleted = true
        #expect(AgentRelaySource.item(from: deleted, calendar: calendar) == nil)
    }

    @Test func decodesSnakeCase() throws {
        let json = #"{"events":[{"id":"x","title":"t","start":"2026-11-03","all_day":true,"updated_at":"2026-10-30T07:00:00Z","deleted":false}],"now":"2026-10-30T15:00:00+08:00"}"#
        struct Response: Decodable { var events: [RelayAgentEvent] }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let events = try d.decode(Response.self, from: Data(json.utf8)).events
        #expect(events.first?.allDay == true)
        #expect(events.first?.updatedAt == "2026-10-30T07:00:00Z")
    }

    @Test func snapshotBodyUsesBeijingTime() throws {
        let course = CalendarItem(sourceKind: .course, sourceID: "c", externalID: "1", title: "数据结构",
                                  location: "45楼B302", start: date(10, 29, 8, 30), end: date(10, 29, 10, 5),
                                  metadata: ["teacher": "李四"])
        let holiday = CalendarItem(sourceKind: .systemCalendar, sourceID: "s", externalID: "2", title: "假期",
                                   start: date(11, 1), end: date(11, 2), isAllDay: true, metadata: ["calendarTitle": "节假日"])
        let body = String(decoding: try RelayClient.snapshotBody([course, holiday], calendar: calendar), as: UTF8.self)
        #expect(body.contains(#""start":"2026-10-29T08:30:00+08:00""#))
        #expect(body.contains(#""notes":"李四""#))
        #expect(body.contains(#""all_day":true"#))
        #expect(body.contains(#""start":"2026-11-01""#))
        #expect(body.contains(#""source":"系统日历 · 节假日""#))
    }
}
