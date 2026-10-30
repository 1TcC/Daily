import Foundation

/// 到 Daily Relay（Cloudflare 中转服务）的连接：`https://<worker>/<密钥>`。
/// Grok 用 `mcpURL` 作为自定义连接器地址；Daily 用同步端点拉取 / 上传。
public struct RelayConnection: Sendable, Equatable {
    public let baseURL: URL

    public init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/mcp") { text.removeLast(4) }
        guard let url = URL(string: text), let host = url.host, url.path.count > 1,
              url.scheme == "https" || (url.scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
        else { return nil }
        baseURL = url
    }

    /// Grok 用的连接器地址（旧地址，保持不变）。
    public var mcpURL: URL { baseURL.appendingPathComponent("mcp") }

    /// 其他 AI 的连接器地址：`/mcp/<名字>`，中转服务据此区分来源和编辑权限。
    public func mcpURL(for client: String) -> URL {
        client == "grok" ? mcpURL : mcpURL.appendingPathComponent(client)
    }
    var agentEventsURL: URL { baseURL.appendingPathComponent("sync/agent-events") }
    var snapshotURL: URL { baseURL.appendingPathComponent("sync/snapshot") }
}

/// 中转服务里 Grok 写入的一条日程。
public struct RelayAgentEvent: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String?
    public var allDay: Bool?
    public var location: String?
    public var notes: String?
    public var updatedAt: String?
    public var deleted: Bool?
    /// 创建它的 AI（grok、muse…）；旧数据没有，视为 grok。
    public var client: String?

    /// 显示用的名字。
    public var clientName: String {
        switch client ?? "grok" {
        case "grok": "Grok"
        case "muse": "Muse"
        case let other: other.prefix(1).uppercased() + other.dropFirst()
        }
    }
}

/// 上传给中转服务、供 Grok 查询的日程快照条目。
struct RelaySnapshotEvent: Codable, Sendable {
    var title: String
    var start: String
    var end: String?
    var allDay: Bool
    var location: String?
    var notes: String?
    var source: String
}

public enum RelayError: Error, LocalizedError {
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .http(404): "中转服务地址或密钥不对（404）"
        case .http(let code): "中转服务返回错误（HTTP \(code)）"
        }
    }
}

/// 中转服务使用的时间格式：北京时间带偏移的 ISO 8601，全天日程为 `YYYY-MM-DD`。
enum RelayTime {
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 解析带偏移的时间；只有日期时按本地日历的当天零点。
    static func date(_ text: String, calendar: Calendar) -> Date? {
        if text.count == 10 {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}

public struct RelayClient: Sendable {
    public let connection: RelayConnection

    public init(connection: RelayConnection) {
        self.connection = connection
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    /// Grok 写入的全部日程（含已删除的墓碑）。
    public func agentEvents() async throws -> [RelayAgentEvent] {
        struct Response: Decodable { var events: [RelayAgentEvent] }
        var request = URLRequest(url: connection.agentEventsURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return try Self.decoder.decode(Response.self, from: data).events
    }

    /// 上传日程快照（Grok 查询时能看到课程、系统日历等）。
    public func uploadSnapshot(_ items: [CalendarItem], calendar: Calendar = .mondayFirst) async throws {
        try await uploadSnapshot(body: Self.snapshotBody(items, calendar: calendar))
    }

    public func uploadSnapshot(body: Data) async throws {
        var request = URLRequest(url: connection.snapshotURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
    }

    /// 快照请求体；内容不变时上传方可以跳过（见 `AgentRelaySource`）。
    public static func snapshotBody(_ items: [CalendarItem], calendar: Calendar = .mondayFirst) throws -> Data {
        struct Body: Encodable { var events: [RelaySnapshotEvent] }
        let events = items.map { item in
            RelaySnapshotEvent(
                title: item.title,
                start: item.isAllDay ? RelayTime.dayString(item.start, calendar: calendar) : RelayTime.string(item.start),
                end: item.end.map { item.isAllDay ? RelayTime.dayString($0, calendar: calendar) : RelayTime.string($0) },
                allDay: item.isAllDay,
                location: item.location,
                notes: item.metadata["teacher"] ?? item.notes,
                source: item.metadata["calendarTitle"].map { "\(item.sourceKind.displayName) · \($0)" }
                    ?? item.sourceKind.displayName
            )
        }
        let encoder = Self.encoder
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Body(events: events))
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RelayError.http(http.statusCode)
        }
    }
}

/// 把中转服务里 Grok 写入的日程同步成「Agent / Bot 写入」来源。
public struct AgentRelaySource: SourceProvider {
    public static let id = "agent-relay"
    public let sourceID = AgentRelaySource.id
    public let kind = SourceKind.agent
    public let displayName = "AI 助手"
    public let client: RelayClient

    public init(client: RelayClient) {
        self.client = client
    }

    public func fetch(in range: DateInterval) async throws -> [CalendarItem] {
        let calendar = Calendar.mondayFirst
        return try await client.agentEvents()
            .compactMap { Self.item(from: $0, calendar: calendar) }
            .filter { $0.overlaps(range) }
    }

    public static func item(from event: RelayAgentEvent, calendar: Calendar) -> CalendarItem? {
        guard event.deleted != true, let start = RelayTime.date(event.start, calendar: calendar) else { return nil }
        let allDay = event.allDay ?? (event.start.count == 10)
        var end = event.end.flatMap { RelayTime.date($0, calendar: calendar) }
        if allDay, end == nil { end = calendar.date(byAdding: .day, value: 1, to: start) }
        return CalendarItem(
            sourceKind: .agent,
            sourceID: id,
            externalID: event.id,
            title: event.title,
            notes: event.notes,
            location: event.location,
            start: start,
            end: end,
            isAllDay: allDay,
            metadata: ["relayID": event.id, "via": event.clientName]
        )
    }
}
