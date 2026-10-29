import Foundation

/// 把原始 VEVENT 转换为 `range` 内的 `ICSEvent` 实例（展开 RRULE、应用 EXDATE 与 RECURRENCE-ID 覆盖）。
enum ICSEventBuilder {
    private struct Timing {
        var start: ICSDateValue
        var end: Date?
        var calendar: Calendar
    }

    static func events(from raws: [ICSRawEvent], in range: DateInterval) -> [ICSEvent] {
        let local = Calendar.current.timeZone
        var masters: [(index: Int, raw: ICSRawEvent)] = []
        var overrides: [(index: Int, raw: ICSRawEvent)] = []
        for (i, raw) in raws.enumerated() {
            if raw.recurrenceID != nil { overrides.append((i, raw)) } else { masters.append((i, raw)) }
        }
        func uid(_ raw: ICSRawEvent, _ index: Int) -> String { raw.uid ?? "ics-event-\(index)" }

        // 被覆盖（或取消）的原始发生时间，按 UID 归类
        var replaced: [String: Set<Date>] = [:]
        for (i, o) in overrides {
            let id = uid(o, i)
            let masterTZ = masters.first { uid($0.raw, $0.index) == id }
                .flatMap { timing(of: $0.raw, local: local)?.start.timeZone }
            guard let rid = o.recurrenceID,
                  let v = ICSDateParser.parse(rid.value, params: rid.params,
                                              fallback: masterTZ ?? timing(of: o, local: local)?.start.timeZone ?? local)
            else { continue }
            replaced[id, default: []].insert(v.date)
        }

        var result: [ICSEvent] = []
        func overlaps(_ start: Date, _ end: Date?) -> Bool {
            start < range.end && (end ?? start) >= range.start
        }
        func event(_ raw: ICSRawEvent, _ id: String, start: Date, end: Date?, allDay: Bool) -> ICSEvent {
            ICSEvent(uid: id, summary: raw.summary ?? "",
                     description: raw.description.flatMap { $0.isEmpty ? nil : $0 },
                     location: raw.location.flatMap { $0.isEmpty ? nil : $0 },
                     start: start, end: end, isAllDay: allDay)
        }

        for (i, raw) in overrides where raw.status != "CANCELLED" {
            guard let t = timing(of: raw, local: local), overlaps(t.start.date, t.end) else { continue }
            result.append(event(raw, uid(raw, i), start: t.start.date, end: t.end, allDay: t.start.isDate))
        }

        for (i, raw) in masters where raw.status != "CANCELLED" {
            guard let t = timing(of: raw, local: local) else { continue }
            let id = uid(raw, i)
            let allDay = t.start.isDate
            guard let rule = raw.rrule.flatMap({ ICSRecurrenceRule($0, timeZone: t.start.timeZone) }) else {
                if overlaps(t.start.date, t.end) {
                    result.append(event(raw, id, start: t.start.date, end: t.end, allDay: allDay))
                }
                continue
            }

            var excluded = replaced[id] ?? []
            var excludedDays: [Date] = []  // 时间型事件上的仅日期 EXDATE
            for ex in raw.exdates {
                for piece in ex.value.split(separator: ",") {
                    guard let v = ICSDateParser.parse(String(piece), params: ex.params, fallback: t.start.timeZone) else { continue }
                    if v.isDate && !allDay { excludedDays.append(v.date) } else { excluded.insert(v.date) }
                }
            }

            let cal = t.calendar
            let interval = t.end.map { $0.timeIntervalSince(t.start.date) }
            let dayCount = Int(((interval ?? 86400) / 86400).rounded())
            let expander = ICSRecurrenceExpander(rule: rule, start: t.start.date, calendar: cal)
            let skipBefore = range.start.addingTimeInterval(-max(interval ?? 0, 0) - 2 * 86400)
            expander.enumerate(skipBefore: skipBefore, end: range.end) { occ in
                let end: Date? = if let interval { allDay ? cal.date(byAdding: .day, value: dayCount, to: occ) : occ.addingTimeInterval(interval) } else { nil }
                guard overlaps(occ, end), !excluded.contains(occ),
                      !excludedDays.contains(where: { cal.isDate(occ, inSameDayAs: $0) }) else { return }
                result.append(event(raw, id, start: occ, end: end, allDay: allDay))
            }
        }

        return result.sorted { ($0.start, $0.uid) < ($1.start, $1.uid) }
    }

    private static func timing(of raw: ICSRawEvent, local: TimeZone) -> Timing? {
        guard let p = raw.dtstart,
              let start = ICSDateParser.parse(p.value, params: p.params, fallback: local) else { return nil }
        let cal = ICSDateParser.calendar(start.timeZone)
        var end: Date?
        if let e = raw.dtend, let v = ICSDateParser.parse(e.value, params: e.params, fallback: start.timeZone) {
            end = v.date
        } else if let d = raw.duration, let comps = ICSDateParser.parseDuration(d) {
            end = cal.date(byAdding: comps, to: start.date)
        } else if start.isDate {
            end = cal.date(byAdding: .day, value: 1, to: start.date)
        }
        return Timing(start: start, end: end, calendar: cal)
    }
}
