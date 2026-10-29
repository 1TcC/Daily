import Foundation

/// 条目状态：AI 识别出的条目先是 `pending`，用户确认后变为 `confirmed`。
public enum ItemStatus: String, Codable, Sendable {
    case confirmed
    case pending
    case dismissed
}

/// 所有来源统一后的日程条目。
public struct CalendarItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceKind: SourceKind
    /// 具体来源的标识，例如某个 ICS 订阅或某个邮箱账号；手动条目为 "manual"。
    public var sourceID: String
    /// 来源内的唯一键，用于同步时去重；手动条目为 nil。
    public var externalID: String?
    public var title: String
    public var notes: String?
    public var location: String?
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var status: ItemStatus
    /// 来源相关的附加信息，例如取件码、车次座位、订阅金额。
    public var metadata: [String: String]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceKind: SourceKind,
        sourceID: String,
        externalID: String? = nil,
        title: String,
        notes: String? = nil,
        location: String? = nil,
        start: Date,
        end: Date? = nil,
        isAllDay: Bool = false,
        status: ItemStatus = .confirmed,
        metadata: [String: String] = [:],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.externalID = externalID
        self.title = title
        self.notes = notes
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.status = status
        self.metadata = metadata
        self.updatedAt = updatedAt
    }

    /// 无结束时间的条目（如「快递待取件」）按时间点处理，结束时间视为开始时间。
    public var effectiveEnd: Date { end ?? start }

    public func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && effectiveEnd >= interval.start
    }
}
