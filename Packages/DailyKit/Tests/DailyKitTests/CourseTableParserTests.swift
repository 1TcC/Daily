import Testing
@testable import DailyKit

@Suite struct CourseTableParserTests {
    // MARK: parseWeeks

    @Test func weeksRange() {
        #expect(CourseTableParser.parseWeeks("4-19 周") == Array(4...19))
        #expect(CourseTableParser.parseWeeks("4-19") == Array(4...19))
        #expect(CourseTableParser.parseWeeks("第1-16周") == Array(1...16))
    }

    @Test func weeksSingleAndList() {
        #expect(CourseTableParser.parseWeeks("3周") == [3])
        #expect(CourseTableParser.parseWeeks("3,5,7周") == [3, 5, 7])
        #expect(CourseTableParser.parseWeeks("3，5，7 周") == [3, 5, 7])
    }

    @Test func weeksParityPrefix() {
        #expect(CourseTableParser.parseWeeks("单5-19 周") == [5, 7, 9, 11, 13, 15, 17, 19])
        #expect(CourseTableParser.parseWeeks("双4-18 周") == [4, 6, 8, 10, 12, 14, 16, 18])
    }

    @Test func weeksParitySuffix() {
        let odd = [1, 3, 5, 7, 9, 11, 13, 15]
        let even = [2, 4, 6, 8, 10, 12, 14, 16]
        #expect(CourseTableParser.parseWeeks("1-16周(单)") == odd)
        #expect(CourseTableParser.parseWeeks("1-16周（双）") == even)
        #expect(CourseTableParser.parseWeeks("1-16单周") == odd)
        #expect(CourseTableParser.parseWeeks("1-16 双周") == even)
        // 末尾标记作用于整个字符串
        #expect(CourseTableParser.parseWeeks("1-4,9-12周(单)") == [1, 3, 9, 11])
    }

    @Test func weeksMultipleSegments() {
        let expected = Array(1...8) + Array(10...16)
        #expect(CourseTableParser.parseWeeks("1-8,10-16周") == expected)
        #expect(CourseTableParser.parseWeeks("1-8，10-16周") == expected)
        #expect(CourseTableParser.parseWeeks("1-8, 10-16 周") == expected)
    }

    @Test func weeksDashVariants() {
        for dash in ["-", "–", "—", "~", "～"] {
            #expect(CourseTableParser.parseWeeks("4\(dash)8周") == [4, 5, 6, 7, 8], "dash: \(dash)")
        }
    }

    @Test func weeksMixedParityPerSegment() {
        #expect(CourseTableParser.parseWeeks("1-4,单7-15周") == [1, 2, 3, 4, 7, 9, 11, 13, 15])
        #expect(CourseTableParser.parseWeeks("双2-6,单9-13周") == [2, 4, 6, 9, 11, 13])
    }

    @Test func weeksSortedUnique() {
        #expect(CourseTableParser.parseWeeks("5-7,1-3,6-8周") == [1, 2, 3, 5, 6, 7, 8])
    }

    @Test func weeksGarbage() {
        #expect(CourseTableParser.parseWeeks("").isEmpty)
        #expect(CourseTableParser.parseWeeks("待定").isEmpty)
        #expect(CourseTableParser.parseWeeks("abc-def周").isEmpty)
        #expect(CourseTableParser.parseWeeks("9-3周").isEmpty)
    }

    // MARK: parseCell

    private func cell(_ text: String, title: String? = nil, weekday: Int = 2,
                      start: Int = 3, span: Int = 2) -> RawCourseCell {
        RawCourseCell(weekday: weekday, startUnit: start, unitSpan: span, text: text, title: title)
    }

    @Test func singleCourseFromText() {
        let entries = CourseTableParser.parseCell(cell("示例原理 (张三)\n(4-19 周,46楼A405)"))
        #expect(entries == [
            CourseEntry(name: "示例原理", teacher: "张三", room: "46楼A405", weekday: 2,
                        startUnit: 3, endUnit: 4, weeks: Array(4...19), weeksText: "4-19 周")
        ])
    }

    @Test func twoCoursesFromText() {
        let text = "数据结构 (李四)\n(12-19 周,45楼B302)\n数据结构 (王五)\n(4-11 周,45楼B302)"
        let entries = CourseTableParser.parseCell(cell(text))
        #expect(entries.count == 2)
        #expect(entries[0].teacher == "李四")
        #expect(entries[0].weeks == Array(12...19))
        #expect(entries[1].teacher == "王五")
        #expect(entries[1].weeks == Array(4...11))
        #expect(entries.allSatisfy { $0.name == "数据结构" && $0.room == "45楼B302" })
    }

    @Test func twoCoursesFromTitle() {
        let title = "数据结构 (李四);;;(12-19 周,45楼B302);;;数据结构 (王五);;;(4-11 周,45楼B302)"
        let entries = CourseTableParser.parseCell(cell("忽略", title: title))
        #expect(entries.map(\.teacher) == ["李四", "王五"])
        #expect(entries.map(\.weeksText) == ["12-19 周", "4-11 周"])
    }

    @Test func noRoom() {
        let entries = CourseTableParser.parseCell(cell("体育C (赵六)\n(4-19 周)"))
        #expect(entries.count == 1)
        #expect(entries[0].room == nil)
        #expect(entries[0].weeks == Array(4...19))
        #expect(entries[0].weeksText == "4-19 周")
    }

    @Test func nameWithInnerParentheses() {
        let entries = CourseTableParser.parseCell(cell("体育C(篮球) (赵六)\n(1-8周,体育馆)"))
        #expect(entries.count == 1)
        #expect(entries[0].name == "体育C(篮球)")
        #expect(entries[0].teacher == "赵六")
        #expect(entries[0].room == "体育馆")
    }

    @Test func fullWidthParensAndComma() {
        let entries = CourseTableParser.parseCell(cell("示例英语（钱七）\n（单5-19 周，45楼B115）"))
        #expect(entries.count == 1)
        #expect(entries[0].name == "示例英语")
        #expect(entries[0].teacher == "钱七")
        #expect(entries[0].room == "45楼B115")
        #expect(entries[0].weeksText == "单5-19 周")
        #expect(entries[0].weeks == [5, 7, 9, 11, 13, 15, 17, 19])
    }

    @Test func teacherListKeptAsIs() {
        let entries = CourseTableParser.parseCell(cell("示例导论 (张三,李四)\n(1-8周,A101)"))
        #expect(entries[0].teacher == "张三,李四")
        #expect(entries[0].room == "A101")
    }

    @Test func noTeacher() {
        let entries = CourseTableParser.parseCell(cell("自习\n(1-8周,A101)"))
        #expect(entries[0].name == "自习")
        #expect(entries[0].teacher == nil)
    }

    @Test func titlePreferredOverText() {
        let entries = CourseTableParser.parseCell(cell(
            "文本课程 (甲)\n(1-2周)",
            title: "学术写作 (钱七);;;(单5-19 周,45楼B115)"))
        #expect(entries.count == 1)
        #expect(entries[0].name == "学术写作")
        #expect(entries[0].weeksText == "单5-19 周")
    }

    @Test func fallsBackToTextWhenTitleEmpty() {
        let text = "示例原理 (张三)\n(4-19 周,46楼A405)"
        let expected = CourseTableParser.parseCell(cell(text))
        #expect(expected.count == 1)
        #expect(CourseTableParser.parseCell(cell(text, title: "")) == expected)
        #expect(CourseTableParser.parseCell(cell(text, title: " ;;;;;; ")) == expected)
    }

    @Test func emptySegmentsSkipped() {
        let entries = CourseTableParser.parseCell(cell("", title: ";;;示例原理 (张三);;;;;;(4-19 周,A405);;;"))
        #expect(entries.count == 1)
        #expect(entries[0].room == "A405")
    }

    @Test func blankLinesIgnored() {
        let text = "\n示例原理 (张三)\n\n  \n(4-19 周,46楼A405)\n\n数据结构 (李四)\n\n(1-3 周)\n"
        let entries = CourseTableParser.parseCell(cell(text))
        #expect(entries.map(\.name) == ["示例原理", "数据结构"])
        #expect(entries[1].weeks == [1, 2, 3])
    }

    @Test func courseWithoutDetail() {
        let entries = CourseTableParser.parseCell(cell("示例原理 (张三)\n数据结构 (李四)\n(1-3 周)"))
        #expect(entries.count == 2)
        #expect(entries[0].weeks.isEmpty)
        #expect(entries[0].weeksText == "")
        #expect(entries[1].weeks == [1, 2, 3])
    }

    @Test func endUnitFromSpan() {
        let text = "示例原理 (张三)\n(1-8周)"
        #expect(CourseTableParser.parseCell(cell(text, start: 5, span: 3))[0].endUnit == 7)
        #expect(CourseTableParser.parseCell(cell(text, start: 5, span: 1))[0].endUnit == 5)
        #expect(CourseTableParser.parseCell(cell(text, start: 5, span: 0))[0].endUnit == 5)
        let e = CourseTableParser.parseCell(cell(text, weekday: 5, start: 5, span: 3))[0]
        #expect(e.weekday == 5 && e.startUnit == 5)
    }

    @Test func emptyCell() {
        #expect(CourseTableParser.parseCell(cell("")).isEmpty)
    }

    // MARK: parseUnits

    @Test func unitsFromLabels() {
        let units = CourseTableParser.parseUnits([
            RawUnitLabel(index: 1, text: "第一节\n08:30-09:15"),
            RawUnitLabel(index: 12, text: "第十二节 21:00-21:45"),
            RawUnitLabel(index: 2, text: "1\n8:00~8:45"),
            RawUnitLabel(index: 3, text: "第3节 10:25—11:10"),
            RawUnitLabel(index: 4, text: "第4节 10：25～11：10"),
        ])
        #expect(units == [
            CourseUnit(index: 1, startMinute: 8 * 60 + 30, endMinute: 9 * 60 + 15),
            CourseUnit(index: 2, startMinute: 8 * 60, endMinute: 8 * 60 + 45),
            CourseUnit(index: 3, startMinute: 10 * 60 + 25, endMinute: 11 * 60 + 10),
            CourseUnit(index: 4, startMinute: 10 * 60 + 25, endMinute: 11 * 60 + 10),
            CourseUnit(index: 12, startMinute: 21 * 60, endMinute: 21 * 60 + 45),
        ])
    }

    @Test func unitsSkipLabelWithoutTime() {
        let units = CourseTableParser.parseUnits([
            RawUnitLabel(index: 1, text: "第一节"),
            RawUnitLabel(index: 2, text: "第二节\n09:20-10:05"),
        ])
        #expect(units.map(\.index) == [2])
    }
}
