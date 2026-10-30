import Foundation
import Testing
@testable import DailyKit

@Suite struct CourseScheduleTests {
    let calendar: Calendar = {
        var cal = Calendar.mondayFirst
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    func date(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    var table: RawCourseTable {
        RawCourseTable(
            semester: "2026-2027学年1学期",
            units: [RawUnitLabel(index: 1, text: "第一节\n08:30-09:15"), RawUnitLabel(index: 2, text: "第二节\n09:20-10:05"),
                    RawUnitLabel(index: 7, text: "第七节\n15:25-16:10"), RawUnitLabel(index: 8, text: "第八节\n16:15-17:00")],
            cells: [
                RawCourseCell(weekday: 4, startUnit: 1, unitSpan: 2,
                              text: "数据结构 (李四)\n(12-19 周,45楼B302)\n数据结构 (王五)\n(4-11 周,45楼B302)"),
                RawCourseCell(weekday: 3, startUnit: 7, unitSpan: 2, text: "学术写作 (钱七)\n\n(单5-19 周,45楼B115)"),
            ]
        )
    }

    @Test func expandsWeeksIntoDates() {
        let schedule = CourseSchedule.build(from: table, firstMonday: date(8, 31), calendar: calendar)
        #expect(schedule.semester == "2026-2027学年1学期")
        #expect(schedule.courses.count == 3)

        // 第 9 周（10/26–11/1）：周四 1-2 节的数据结构由第二位老师上（4-11 周）
        let week9 = DateInterval(start: date(10, 26), end: date(11, 2))
        let items = schedule.items(in: week9, calendar: calendar)
        let thursday = items.filter { $0.title == "数据结构" }
        #expect(thursday.count == 1)
        #expect(thursday.first?.notes == "王五")
        #expect(thursday.first?.start == date(10, 29, 8, 30))
        #expect(thursday.first?.end == date(10, 29, 10, 5))
        #expect(thursday.first?.location == "45楼B302")

        // 单周课程：第 9 周有，第 10 周没有
        #expect(items.contains { $0.title == "学术写作" && $0.start == date(10, 28, 15, 25) })
        let week10 = DateInterval(start: date(11, 2), end: date(11, 9))
        #expect(!schedule.items(in: week10, calendar: calendar).contains { $0.title == "学术写作" })
    }

    @Test func weekNumberAndDistinctIDs() {
        let schedule = CourseSchedule.build(from: table, firstMonday: date(8, 31), calendar: calendar)
        #expect(schedule.week(of: date(10, 30), calendar: calendar) == 9)
        #expect(schedule.week(of: date(8, 30), calendar: calendar) == nil)
        #expect(schedule.lastWeek == 19)
        let all = schedule.items(in: DateInterval(start: date(8, 31), end: date(12, 31)), calendar: calendar)
        #expect(Set(all.compactMap(\.externalID)).count == all.count)
    }

    @Test func fallsBackToDefaultUnits() {
        var raw = table
        raw.units = []
        #expect(CourseSchedule.build(from: raw, firstMonday: date(8, 31), calendar: calendar).units.count == 12)
    }

    @Test func persistsInStore() throws {
        let store = try ItemStore.inMemory()
        #expect(try store.courseSchedule() == nil)
        try store.saveCourseSchedule(CourseSchedule.build(from: table, firstMonday: date(8, 31), calendar: calendar))
        #expect(try store.courseSchedule()?.courses.count == 3)
        try store.saveCourseSchedule(nil)
        #expect(try store.courseSchedule() == nil)
    }
}
