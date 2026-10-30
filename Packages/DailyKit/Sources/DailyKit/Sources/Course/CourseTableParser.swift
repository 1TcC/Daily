import Foundation

/// 把网页课表里的文字解析成结构化的课程安排。
public enum CourseTableParser {
    /// 解析周次写法，返回升序、去重的教学周。
    /// 例如「4-19 周」「单5-19 周」「双4-18 周」「1-8,10-16周」「3周」「1-16周(单)」。
    public static func parseWeeks(_ spec: String) -> [Int] {
        var s = normalize(spec)

        // 写在末尾、作用于整个字符串的单双周标记
        var wholeParity: Parity?
        for (marker, parity) in [("(单)", Parity.odd), ("(双)", .even), ("单周", .odd), ("双周", .even)]
        where s.contains(marker) {
            wholeParity = wholeParity ?? parity
            s = s.replacingOccurrences(of: marker, with: "")
        }
        s.removeAll { $0 == "周" || $0 == "第" }

        var weeks = Set<Int>()
        for var segment in s.split(separator: ",") {
            // 前缀的单/双只作用于它所在的这一段
            var parity = wholeParity
            if segment.contains("单") { parity = .odd } else if segment.contains("双") { parity = .even }
            segment.removeAll { $0 == "单" || $0 == "双" }

            let bounds = segment.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard (1...2).contains(bounds.count), !bounds.contains(nil) else { continue }
            let lo = bounds[0]!, hi = bounds.last!!
            guard lo >= 1, lo <= hi, hi <= 99 else { continue }
            for week in lo...hi where parity?.matches(week) ?? true {
                weeks.insert(week)
            }
        }
        return weeks.sorted()
    }

    /// 解析一个格子，可能包含多门课（例如同一时段不同老师、不同周次）。
    public static func parseCell(_ cell: RawCourseCell) -> [CourseEntry] {
        let endUnit = cell.startUnit + max(cell.unitSpan, 1) - 1

        func entries(from lines: [String]) -> [CourseEntry] {
            var result: [CourseEntry] = []
            for line in lines {
                if isParenthesized(line) {
                    // 详情行：补到上一门还没有详情的课上
                    guard let last = result.last, last.weeksText.isEmpty, last.weeks.isEmpty else { continue }
                    let (weeksText, room) = splitDetail(line)
                    result[result.count - 1].weeks = parseWeeks(weeksText)
                    result[result.count - 1].weeksText = weeksText
                    result[result.count - 1].room = room
                } else {
                    let (name, teacher) = splitCourseLine(line)
                    result.append(CourseEntry(name: name, teacher: teacher, weekday: cell.weekday,
                                              startUnit: cell.startUnit, endUnit: endUnit,
                                              weeks: [], weeksText: ""))
                }
            }
            return result
        }

        if let title = cell.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let parsed = entries(from: nonEmptyLines(title.components(separatedBy: ";;;")))
            if !parsed.isEmpty { return parsed }
        }
        return entries(from: nonEmptyLines(cell.text.components(separatedBy: .newlines)))
    }

    /// 从节次标签里解析上下课时间；没有时间的节次会被跳过。
    public static func parseUnits(_ labels: [RawUnitLabel]) -> [CourseUnit] {
        let timeRange = #/(\d{1,2})[:：](\d{2})\s*[-–—~～－]\s*(\d{1,2})[:：](\d{2})/#
        return labels.compactMap { label in
            guard let m = label.text.firstMatch(of: timeRange),
                  let h1 = Int(m.1), let m1 = Int(m.2), let h2 = Int(m.3), let m2 = Int(m.4)
            else { return nil }
            return CourseUnit(index: label.index, startMinute: h1 * 60 + m1, endMinute: h2 * 60 + m2)
        }
        .sorted { $0.index < $1.index }
    }

    // MARK: - 私有辅助

    private enum Parity {
        case odd, even
        func matches(_ week: Int) -> Bool { (week % 2 == 1) == (self == .odd) }
    }

    /// 去掉空白，并把全角标点、各种横线统一成 ASCII。
    private static func normalize(_ text: String) -> String {
        var out = ""
        for ch in text where !ch.isWhitespace {
            switch ch {
            case "，", "、", ";", "；": out.append(",")
            case "（": out.append("(")
            case "）": out.append(")")
            case "–", "—", "~", "～", "－": out.append("-")
            case "０"..."９":
                let digit = ch.unicodeScalars.first!.value - 0xFF10
                out.append(Character(Unicode.Scalar(0x30 + digit)!))
            default: out.append(ch)
            }
        }
        return out
    }

    private static func nonEmptyLines(_ parts: [String]) -> [String] {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func isOpen(_ ch: Character) -> Bool { ch == "(" || ch == "（" }
    private static func isClose(_ ch: Character) -> Bool { ch == ")" || ch == "）" }

    /// 整行被一对括号包住，即「详情行」。
    private static func isParenthesized(_ line: String) -> Bool {
        guard let first = line.first, let last = line.last, line.count >= 2 else { return false }
        return isOpen(first) && isClose(last)
    }

    /// 「名称 (教师)」→ (名称, 教师)；教师取最后一组括号，没有括号则整行是名称。
    private static func splitCourseLine(_ line: String) -> (name: String, teacher: String?) {
        guard let last = line.last, isClose(last) else { return (line, nil) }
        var depth = 0
        var index = line.endIndex
        while index > line.startIndex {
            index = line.index(before: index)
            if isClose(line[index]) { depth += 1 }
            else if isOpen(line[index]) {
                depth -= 1
                if depth == 0 {
                    let name = line[..<index].trimmingCharacters(in: .whitespaces)
                    let teacher = line[line.index(after: index)..<line.index(before: line.endIndex)]
                        .trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return (line, nil) }
                    return (name, teacher.isEmpty ? nil : teacher)
                }
            }
        }
        return (line, nil) // 括号不配对
    }

    /// 「(周次,教室)」→ (周次原文, 教室)，按第一个中英文逗号拆。
    private static func splitDetail(_ line: String) -> (weeksText: String, room: String?) {
        let inner = String(line.dropFirst().dropLast())
        guard let comma = inner.firstIndex(where: { $0 == "," || $0 == "，" }) else {
            return (inner.trimmingCharacters(in: .whitespaces), nil)
        }
        let weeksText = inner[..<comma].trimmingCharacters(in: .whitespaces)
        let room = inner[inner.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (weeksText, room.isEmpty ? nil : room)
    }
}
