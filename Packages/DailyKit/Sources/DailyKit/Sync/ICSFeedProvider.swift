import Foundation

/// ICS / webcal 订阅源：学校课表导出、节假日、Google / iCloud 公开日历等。
public struct ICSFeedProvider: SourceProvider {
    public let sourceID: String
    public let kind: SourceKind
    public let displayName: String
    public let url: URL

    public init(sourceID: String, displayName: String, url: URL, kind: SourceKind = .systemCalendar) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.url = url
        self.kind = kind
    }

    public func fetch(in range: DateInterval) async throws -> [CalendarItem] {
        let text = try await Self.load(url)
        return try ICSParser.parse(text, expandingIn: range).map { event in
            CalendarItem(
                sourceKind: kind,
                sourceID: sourceID,
                externalID: event.instanceID,
                title: event.summary,
                notes: event.description,
                location: event.location,
                start: event.start,
                end: event.end,
                isAllDay: event.isAllDay
            )
        }
    }

    static func load(_ url: URL) async throws -> String {
        if url.isFileURL {
            return try String(contentsOf: url, encoding: .utf8)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == "webcal" { components?.scheme = "https" }
        let (data, response) = try await URLSession.shared.data(from: components?.url ?? url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
