import Foundation

/// 一节课的上下课时间（作息时间表里的一行），以当天零点起的分钟数表示。
public struct CourseUnit: Codable, Hashable, Sendable {
    /// 第几节，从 1 开始。
    public var index: Int
    public var startMinute: Int
    public var endMinute: Int

    public init(index: Int, startMinute: Int, endMinute: Int) {
        self.index = index
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// 课表里的一门课在某个时间段的安排。同一格里不同老师 / 不同周次的课是不同的条目。
public struct CourseEntry: Codable, Hashable, Sendable {
    public var name: String
    public var teacher: String?
    public var room: String?
    /// 1 = 周一 … 7 = 周日。
    public var weekday: Int
    public var startUnit: Int
    public var endUnit: Int
    /// 上课的教学周，升序。
    public var weeks: [Int]
    /// 原始的周次写法，例如「单5-19 周」，用于展示。
    public var weeksText: String

    public init(name: String, teacher: String? = nil, room: String? = nil, weekday: Int,
                startUnit: Int, endUnit: Int, weeks: [Int], weeksText: String) {
        self.name = name
        self.teacher = teacher
        self.room = room
        self.weekday = weekday
        self.startUnit = startUnit
        self.endUnit = endUnit
        self.weeks = weeks
        self.weeksText = weeksText
    }
}

/// 网页课表表格里的一个格子（由 App 内浏览器里的脚本提取）。
public struct RawCourseCell: Codable, Hashable, Sendable {
    /// 1 = 周一 … 7 = 周日。
    public var weekday: Int
    /// 起始节次，从 1 开始。
    public var startUnit: Int
    /// 跨几节（表格的 rowspan）。
    public var unitSpan: Int
    /// 格子里看到的文字（innerText，换行分隔）。
    public var text: String
    /// 格子的 title 属性（悬停提示），EAMS 里是用 ";;;" 分隔的结构化文本，可能为空。
    public var title: String?

    public init(weekday: Int, startUnit: Int, unitSpan: Int, text: String, title: String? = nil) {
        self.weekday = weekday
        self.startUnit = startUnit
        self.unitSpan = unitSpan
        self.text = text
        self.title = title
    }
}

/// 网页课表第一列的节次标签，例如「第一节\n08:30-09:15」。
public struct RawUnitLabel: Codable, Hashable, Sendable {
    public var index: Int
    public var text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

/// App 内浏览器脚本提取到的整张课表。
public struct RawCourseTable: Codable, Sendable {
    public var semester: String?
    public var units: [RawUnitLabel]
    public var cells: [RawCourseCell]

    public init(semester: String? = nil, units: [RawUnitLabel], cells: [RawCourseCell]) {
        self.semester = semester
        self.units = units
        self.cells = cells
    }
}

/// 导入后保存下来的一学期课表；日程条目由它按周次展开生成。
public struct CourseSchedule: Codable, Sendable {
    public var semester: String?
    /// 第一周的周一（当天零点）。
    public var firstMonday: Date
    public var units: [CourseUnit]
    public var courses: [CourseEntry]
    public var importedAt: Date

    public init(semester: String?, firstMonday: Date, units: [CourseUnit], courses: [CourseEntry], importedAt: Date = .now) {
        self.semester = semester
        self.firstMonday = firstMonday
        self.units = units
        self.courses = courses
        self.importedAt = importedAt
    }
}
