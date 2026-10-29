import Foundation

/// 解析后的日期/时间值。
struct ICSDateValue: Sendable {
    var date: Date
    var isDate: Bool
    var timeZone: TimeZone
}

enum ICSDateParser {
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        return cal
    }

    /// 支持 `yyyyMMdd`、`yyyyMMddTHHmmss`、`...Z`，以及 `TZID` 参数；
    /// 浮动时间与未知时区使用 `fallback`。
    static func parse(_ raw: String, params: [String: String], fallback: TimeZone) -> ICSDateValue? {
        let value = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let parts = value.split(separator: "T", maxSplits: 1)
        guard let datePart = parts.first, datePart.count == 8, let ymd = Int(datePart) else { return nil }
        let isDate = params["VALUE"]?.uppercased() == "DATE" || parts.count == 1

        var comps = DateComponents(year: ymd / 10000, month: ymd / 100 % 100, day: ymd % 100)
        var timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? fallback
        if !isDate {
            guard parts.count == 2 else { return nil }
            var time = parts[1]
            if time.hasSuffix("Z") { time.removeLast(); timeZone = TimeZone(identifier: "UTC")! }
            guard time.count >= 4, let hms = Int(time) else { return nil }
            let scaled = time.count == 4 ? hms * 100 : hms
            comps.hour = scaled / 10000
            comps.minute = scaled / 100 % 100
            comps.second = scaled % 100
        }
        guard let date = calendar(timeZone).date(from: comps) else { return nil }
        return ICSDateValue(date: date, isDate: isDate, timeZone: timeZone)
    }

    /// 解析 ISO 8601 持续时间（`P1DT2H30M`、`PT45M`、`-P1W`）。
    static func parseDuration(_ raw: String) -> DateComponents? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        guard s.hasPrefix("P") else { return nil }
        s.removeFirst()
        var comps = DateComponents(day: 0, hour: 0, minute: 0, second: 0)
        var number = ""
        var inTime = false
        for ch in s {
            if ch.isNumber { number.append(ch); continue }
            if ch == "T" { inTime = true; continue }
            guard let n = Int(number) else { return nil }
            number = ""
            switch (ch, inTime) {
            case ("W", false): comps.day! += 7 * n * sign
            case ("D", false): comps.day! += n * sign
            case ("H", true): comps.hour = n * sign
            case ("M", true): comps.minute = n * sign
            case ("S", true): comps.second = n * sign
            default: return nil
            }
        }
        return comps
    }
}
