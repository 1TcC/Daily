import Foundation

public extension CourseSchedule {
    /// 天津大学的作息时间，网页上没有解析到节次时间时使用。
    static let defaultUnits: [CourseUnit] = [
        (8, 30), (9, 20), (10, 25), (11, 15), (13, 30), (14, 20),
        (15, 25), (16, 15), (18, 30), (19, 20), (20, 10), (21, 0),
    ].enumerated().map { i, t in
        let start = t.0 * 60 + t.1
        return CourseUnit(index: i + 1, startMinute: start, endMinute: start + 45)
    }

    /// 由网页上提取的课表生成可保存的课表。
    static func build(from table: RawCourseTable, firstMonday: Date, calendar: Calendar = .mondayFirst) -> CourseSchedule {
        let units = CourseTableParser.parseUnits(table.units)
        return CourseSchedule(
            semester: table.semester,
            firstMonday: calendar.startOfDay(for: firstMonday),
            units: units.isEmpty ? defaultUnits : units,
            courses: table.cells.flatMap(CourseTableParser.parseCell)
        )
    }

    /// 本学期的教学周数（最后一门课的最后一周）。
    var lastWeek: Int { courses.flatMap(\.weeks).max() ?? 0 }

    /// 某个日期是第几教学周；第一周之前返回 nil。
    func week(of date: Date, calendar: Calendar = .mondayFirst) -> Int? {
        let days = calendar.dateComponents([.day], from: firstMonday, to: calendar.startOfDay(for: date)).day ?? -1
        return days >= 0 ? days / 7 + 1 : nil
    }

    /// 把课表按周次展开成 `range` 内的日程。
    func items(in range: DateInterval, sourceID: String = CourseScheduleProvider.id,
               calendar: Calendar = .mondayFirst) -> [CalendarItem] {
        let unitsByIndex = Dictionary(units.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [CalendarItem] = []
        for course in courses {
            guard let first = unitsByIndex[course.startUnit], let last = unitsByIndex[course.endUnit] else { continue }
            for week in course.weeks {
                guard let day = calendar.date(byAdding: .day, value: (week - 1) * 7 + course.weekday - 1, to: firstMonday)
                else { continue }
                let start = day.addingTimeInterval(TimeInterval(first.startMinute * 60))
                let end = day.addingTimeInterval(TimeInterval(last.endMinute * 60))
                guard start < range.end, end > range.start else { continue }
                var metadata = ["weeks": course.weeksText, "units": "第\(course.startUnit)-\(course.endUnit)节", "week": "\(week)"]
                if let teacher = course.teacher { metadata["teacher"] = teacher }
                result.append(CalendarItem(
                    sourceKind: .course,
                    sourceID: sourceID,
                    externalID: "\(course.name)#\(course.teacher ?? "")#\(course.weekday)#\(course.startUnit)#\(week)",
                    title: course.name,
                    notes: course.teacher,
                    location: course.room,
                    start: start,
                    end: end,
                    metadata: metadata
                ))
            }
        }
        return result
    }
}

/// 把导入的课表展开成「教务课程」日程。
public struct CourseScheduleProvider: SourceProvider {
    public static let id = "course-schedule"
    public let sourceID = CourseScheduleProvider.id
    public let kind = SourceKind.course
    public let displayName = SourceKind.course.displayName
    private let store: ItemStore

    public init(store: ItemStore) {
        self.store = store
    }

    public func fetch(in range: DateInterval) async throws -> [CalendarItem] {
        try store.courseSchedule()?.items(in: range) ?? []
    }
}
