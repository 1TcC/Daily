import Foundation

struct ICSRecurrenceRule: Sendable {
    enum Frequency: Sendable { case daily, weekly, monthly, yearly }
    /// `weekday`：周一 = 0 … 周日 = 6；`ordinal` 为 0 表示不限第几个。
    struct WeekdayRule: Sendable { var ordinal: Int; var weekday: Int }

    var frequency: Frequency
    var interval = 1
    var count: Int?
    /// 含此时刻在内的最后一个允许的起始时间。
    var until: Date?
    var byDay: [WeekdayRule] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []

    private static let weekdays = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]

    /// 不支持的 FREQ（如 HOURLY）返回 nil。
    init?(_ text: String, timeZone: TimeZone) {
        var parts: [String: String] = [:]
        for item in text.split(separator: ";") {
            let kv = item.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        switch parts["FREQ"]?.uppercased() {
        case "DAILY": frequency = .daily
        case "WEEKLY": frequency = .weekly
        case "MONTHLY": frequency = .monthly
        case "YEARLY": frequency = .yearly
        default: return nil
        }
        interval = max(parts["INTERVAL"].flatMap { Int($0) } ?? 1, 1)
        count = parts["COUNT"].flatMap { Int($0) }
        if let u = parts["UNTIL"], let v = ICSDateParser.parse(u, params: [:], fallback: timeZone) {
            if v.isDate {  // 仅日期：当天都算在内
                until = ICSDateParser.calendar(v.timeZone).date(byAdding: .day, value: 1, to: v.date)?
                    .addingTimeInterval(-0.001)
            } else {
                until = v.date
            }
        }
        byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { token in
            let t = token.uppercased()
            guard let wd = Self.weekdays[String(t.suffix(2))] else { return nil }
            let prefix = t.dropLast(2)
            return WeekdayRule(ordinal: prefix.isEmpty ? 0 : Int(prefix) ?? 0, weekday: wd)
        }
        byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
    }
}

/// 在事件所在时区的日历中逐周期生成重复实例的起始时间（保持墙上时间不变）。
struct ICSRecurrenceExpander {
    let rule: ICSRecurrenceRule
    let start: Date
    let calendar: Calendar
    var maxPeriods = 5000

    private struct YMD { var y: Int; var m: Int; var d: Int }

    /// 按时间升序回调每个实例的起始时间，直到超过 `end`、UNTIL、COUNT 或安全上限。
    /// 没有 COUNT 时，会跳过明显早于 `skipBefore` 的周期。
    func enumerate(skipBefore: Date, end: Date, _ body: (Date) -> Void) {
        let t = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let (y0, m0, d0) = (t.year!, t.month!, t.day!)
        let startNoon = noon(YMD(y: y0, m: m0, d: d0))
        let interval = rule.interval

        var period = 0
        if rule.count == nil, skipBefore > start {
            let unit: Calendar.Component = switch rule.frequency {
            case .daily, .weekly: .day
            case .monthly: .month
            case .yearly: .year
            }
            var n = calendar.dateComponents([unit], from: start, to: skipBefore).value(for: unit) ?? 0
            if rule.frequency == .weekly { n /= 7 }
            period = max(0, n / interval - 1)
        }

        func time(_ ymd: YMD) -> Date? {
            calendar.date(from: DateComponents(year: ymd.y, month: ymd.m, day: ymd.d,
                                               hour: t.hour, minute: t.minute, second: t.second))
        }
        func days(of period: Int) -> [YMD] {
            switch rule.frequency {
            case .daily:
                let day = ymd(calendar.date(byAdding: .day, value: period * interval, to: startNoon)!)
                guard rule.byDay.isEmpty || rule.byDay.contains(where: { $0.weekday == weekday(day) }) else { return [] }
                return [day]
            case .weekly:
                let wds = rule.byDay.isEmpty ? [weekday(YMD(y: y0, m: m0, d: d0))]
                                             : Array(Set(rule.byDay.map(\.weekday))).sorted()
                let weekStart = calendar.date(byAdding: .day, value: -weekday(YMD(y: y0, m: m0, d: d0)) + period * interval * 7,
                                              to: startNoon)!
                return wds.map { ymd(calendar.date(byAdding: .day, value: $0, to: weekStart)!) }
            case .monthly:
                let total = y0 * 12 + (m0 - 1) + period * interval
                return monthDays(y: total / 12, m: total % 12 + 1, defaultDay: d0)
            case .yearly:
                let months = rule.byMonth.isEmpty ? [m0] : Array(Set(rule.byMonth)).sorted()
                return months.filter { (1...12).contains($0) }
                    .flatMap { monthDays(y: y0 + period * interval, m: $0, defaultDay: d0) }
            }
        }

        var emitted = 0
        for _ in 0..<maxPeriods {
            for day in days(of: period) {
                guard let occ = time(day), occ >= start else { continue }
                if let until = rule.until, occ > until { return }
                emitted += 1
                if let count = rule.count, emitted > count { return }
                if occ >= end { return }
                body(occ)
            }
            period += 1
        }
    }

    // MARK: - 日历辅助

    private func noon(_ d: YMD) -> Date {
        calendar.date(from: DateComponents(year: d.y, month: d.m, day: d.d, hour: 12))!
    }

    private func ymd(_ date: Date) -> YMD {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return YMD(y: c.year!, m: c.month!, d: c.day!)
    }

    /// 周一 = 0 … 周日 = 6
    private func weekday(_ d: YMD) -> Int {
        (calendar.component(.weekday, from: noon(d)) + 5) % 7
    }

    private func daysInMonth(y: Int, m: Int) -> Int {
        calendar.range(of: .day, in: .month, for: noon(YMD(y: y, m: m, d: 1)))?.count ?? 30
    }

    /// 某月内符合 BYMONTHDAY / BYDAY（含序数）的日；都没有时取 DTSTART 的日。
    /// 不存在的日（如 2 月 30 日）会被丢弃。
    private func monthDays(y: Int, m: Int, defaultDay: Int) -> [YMD] {
        let dim = daysInMonth(y: y, m: m)
        let firstWeekday = weekday(YMD(y: y, m: m, d: 1))
        func weekdayOf(_ day: Int) -> Int { (firstWeekday + day - 1) % 7 }

        var days: [Int]
        if !rule.byMonthDay.isEmpty {
            days = rule.byMonthDay.map { $0 > 0 ? $0 : dim + $0 + 1 }
            if !rule.byDay.isEmpty {
                days = days.filter { d in rule.byDay.contains { $0.weekday == weekdayOf(d) } }
            }
        } else if !rule.byDay.isEmpty {
            days = []
            for r in rule.byDay {
                let matching = (1...dim).filter { weekdayOf($0) == r.weekday }
                if r.ordinal == 0 { days += matching }
                else if r.ordinal > 0, r.ordinal <= matching.count { days.append(matching[r.ordinal - 1]) }
                else if r.ordinal < 0, -r.ordinal <= matching.count { days.append(matching[matching.count + r.ordinal]) }
            }
        } else {
            days = [defaultDay]
        }
        return Set(days.filter { (1...dim).contains($0) }).sorted().map { YMD(y: y, m: m, d: $0) }
    }
}
