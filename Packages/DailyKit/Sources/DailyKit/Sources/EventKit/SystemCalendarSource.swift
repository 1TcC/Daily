import AppKit
import EventKit
import Foundation

/// 系统日历里的一个日历（iCloud、Google、Exchange、订阅日历等）。
public struct SystemCalendarInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// 所属账户，例如「iCloud」「Google」「其他」。
    public var accountName: String
    public var colorHex: String

    public init(id: String, title: String, accountName: String, colorHex: String) {
        self.id = id
        self.title = title
        self.accountName = accountName
        self.colorHex = colorHex
    }
}

public enum CalendarAccess: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

public enum SystemCalendarError: Error, Equatable {
    case notAuthorized
}

/// 系统日历事件的纯数据快照，让映射逻辑可以脱离 EventKit 测试。
public struct SystemEventRecord: Sendable, Hashable {
    public var calendarItemID: String
    public var calendarID: String
    public var title: String?
    public var location: String?
    public var notes: String?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    public init(calendarItemID: String, calendarID: String, title: String?, location: String? = nil,
                notes: String? = nil, start: Date, end: Date, isAllDay: Bool) {
        self.calendarItemID = calendarItemID
        self.calendarID = calendarID
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

/// 通过 EventKit 读取系统日历：Mac 上登录过的 iCloud、Google、Exchange 等账户都会出现在这里。
/// 只读，不回写。EKEventStore 的访问用锁串行化。
public final class SystemCalendarSource: SourceProvider, @unchecked Sendable {
    public let sourceID = "system-calendar"
    public let kind = SourceKind.systemCalendar
    public let displayName = SourceKind.systemCalendar.displayName

    private let eventStore = EKEventStore()
    private let preferences: Preferences
    private let lock = NSLock()

    public init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    public static var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 弹出系统授权框；用户之前拒绝过时不会再弹，只能去系统设置里打开。
    @discardableResult
    public func requestAccess() async -> Bool {
        (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    public func calendars() -> [SystemCalendarInfo] {
        guard Self.access == .granted else { return [] }
        return withLock { eventStore.calendars(for: .event) }
            .map(Self.info)
            .sorted { ($0.accountName, $0.title) < ($1.accountName, $1.title) }
    }

    public func fetch(in range: DateInterval) async throws -> [CalendarItem] {
        guard Self.access == .granted else { throw SystemCalendarError.notAuthorized }
        let excluded = preferences.excludedCalendarIDs
        return withLock {
            let calendars = eventStore.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
            guard !calendars.isEmpty else { return [] }
            let infos = Dictionary(uniqueKeysWithValues: calendars.map { ($0.calendarIdentifier, Self.info($0)) })

            // EventKit 单次查询最多 4 年，按年分段。
            var items: [CalendarItem] = []
            var chunkStart = range.start
            while chunkStart < range.end {
                let chunkEnd = min(range.end, chunkStart.addingTimeInterval(365 * 24 * 3600))
                let predicate = eventStore.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
                for event in eventStore.events(matching: predicate) where event.status != .canceled {
                    // 跨分段的事件只在它开始的那一段里收录，避免重复。
                    guard event.startDate >= chunkStart || chunkStart == range.start else { continue }
                    let record = Self.record(event)
                    items.append(Self.item(from: record, calendar: infos[record.calendarID]))
                }
                chunkStart = chunkEnd
            }
            return items
        }
    }

    // MARK: - 映射

    public static func item(from record: SystemEventRecord, calendar info: SystemCalendarInfo?,
                            calendar: Calendar = .current) -> CalendarItem {
        var end = record.end
        if record.isAllDay {
            // EventKit 的全天事件结束于最后一天 23:59:59，统一成「次日零点」的开区间。
            let dayStart = calendar.startOfDay(for: end)
            if dayStart != end { end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end }
        }
        var metadata = ["calendarID": record.calendarID]
        if let info {
            metadata["calendarTitle"] = info.title
            metadata["color"] = info.colorHex
        }
        let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarItem(
            sourceKind: .systemCalendar,
            sourceID: "system-calendar",
            // 重复事件的每次发生共享 calendarItemIdentifier，加上开始时间区分。
            externalID: "\(record.calendarItemID)#\(Int(record.start.timeIntervalSince1970))",
            title: title.isEmpty ? "（无标题）" : title,
            notes: record.notes.flatMap { $0.isEmpty ? nil : $0 },
            location: record.location.flatMap { $0.isEmpty ? nil : $0 },
            start: record.start,
            end: end,
            isAllDay: record.isAllDay,
            metadata: metadata
        )
    }

    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    private static func info(_ calendar: EKCalendar) -> SystemCalendarInfo {
        let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB)
        return SystemCalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            accountName: calendar.source?.title ?? "其他",
            colorHex: color.map { hex(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) } ?? "#0F8B8D"
        )
    }

    private static func record(_ event: EKEvent) -> SystemEventRecord {
        SystemEventRecord(
            calendarItemID: event.calendarItemIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            title: event.title,
            location: event.location,
            notes: event.notes,
            start: event.startDate,
            end: event.endDate ?? event.startDate,
            isAllDay: event.isAllDay
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
