import Foundation

/// ICS 中的一个事件实例。重复事件在解析时已展开，每次发生对应一个 `ICSEvent`。
public struct ICSEvent: Sendable, Hashable {
    public var uid: String
    public var summary: String
    public var description: String?
    public var location: String?
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool

    public init(uid: String, summary: String, description: String? = nil, location: String? = nil,
                start: Date, end: Date? = nil, isAllDay: Bool = false) {
        self.uid = uid
        self.summary = summary
        self.description = description
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    /// 展开后的实例在来源内的唯一键。
    public var instanceID: String { "\(uid)#\(Int(start.timeIntervalSince1970))" }
}

public enum ICSParserError: Error, Equatable {
    case notACalendar
}

public enum ICSParser {
    /// 解析 ICS 文本，返回 `range` 内发生的所有事件实例（重复事件已展开）。
    public static func parse(_ text: String, expandingIn range: DateInterval) throws -> [ICSEvent] {
        let lines = ICSLexer.unfold(text)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "BEGIN:VCALENDAR" }) else {
            throw ICSParserError.notACalendar
        }
        return ICSEventBuilder.events(from: ICSLexer.rawEvents(from: lines), in: range)
    }
}
