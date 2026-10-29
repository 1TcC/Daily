import Foundation

/// 一行内容行（`NAME;PARAM=V:value`）解析后的结果。
struct ICSProperty: Sendable {
    var name: String
    var params: [String: String]
    var value: String
}

/// VEVENT 中收集到的原始属性。
struct ICSRawEvent: Sendable {
    var uid: String?
    var summary: String?
    var description: String?
    var location: String?
    var status: String?
    var dtstart: ICSProperty?
    var dtend: ICSProperty?
    var duration: String?
    var rrule: String?
    var exdates: [ICSProperty] = []
    var recurrenceID: ICSProperty?
}

enum ICSLexer {
    /// 统一换行符并展开折叠行（后续行以空格/制表符开头）。
    static func unfold(_ text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(String(line))
            }
        }
        return lines
    }

    /// 解析内容行；引号内的 `:` `;` 不作为分隔符。
    static func parseLine(_ line: String) -> ICSProperty? {
        var head: [Character] = []
        var inQuotes = false
        var valueStart: String.Index?
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ":" && !inQuotes { valueStart = line.index(after: idx); break }
            head.append(ch)
            idx = line.index(after: idx)
        }
        guard let valueStart else { return nil }

        var segments: [String] = [""]
        inQuotes = false
        for ch in head {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { segments.append("") } else { segments[segments.count - 1].append(ch) }
        }
        let name = segments[0].trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = seg[..<eq].uppercased()
            let val = seg[seg.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[key] = val
        }
        return ICSProperty(name: name, params: params, value: String(line[valueStart...]))
    }

    /// 还原 TEXT 值的转义：`\n` `\N` `\,` `\;` `\\`。
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                out.append(ch == "n" || ch == "N" ? "\n" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// 提取所有顶层 VEVENT；嵌套块（VALARM 等）内的属性被忽略。
    static func rawEvents(from lines: [String]) -> [ICSRawEvent] {
        var events: [ICSRawEvent] = []
        var stack: [String] = []
        var current: ICSRawEvent?

        for line in lines {
            guard let prop = parseLine(line) else { continue }
            let value = prop.value.trimmingCharacters(in: .whitespaces)
            switch prop.name {
            case "BEGIN":
                stack.append(value.uppercased())
                if stack.last == "VEVENT" && stack.count == 2 { current = ICSRawEvent() }
            case "END":
                let name = value.uppercased()
                if name == "VEVENT" && stack.count == 2, let event = current {
                    events.append(event)
                    current = nil
                }
                if let i = stack.lastIndex(of: name) { stack.removeSubrange(i...) }
            default:
                guard stack.count == 2, stack.last == "VEVENT", var event = current else { continue }
                switch prop.name {
                case "UID": event.uid = value
                case "SUMMARY": event.summary = unescape(prop.value)
                case "DESCRIPTION": event.description = unescape(prop.value)
                case "LOCATION": event.location = unescape(prop.value)
                case "STATUS": event.status = value.uppercased()
                case "DTSTART": event.dtstart = prop
                case "DTEND": event.dtend = prop
                case "DURATION": event.duration = value
                case "RRULE": event.rrule = value
                case "EXDATE": event.exdates.append(prop)
                case "RECURRENCE-ID": event.recurrenceID = prop
                default: break
                }
                current = event
            }
        }
        return events
    }
}
