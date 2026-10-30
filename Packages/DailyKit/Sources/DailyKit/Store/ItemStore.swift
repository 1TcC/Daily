import Foundation

/// 小组件点「已取」后通知 App 的跨进程通知名。
public enum ParcelPick {
    public static let darwinNotification = "com.rain.daily.parcelPicked"
}

/// 日程与订阅的本地存储。数据库放在 App Group 容器里，App 写、Widget 读。
public final class ItemStore: Sendable {
    let db: SQLiteDatabase

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: url.path)
        try migrate()
    }

    /// 测试和开发预览用的内存库。
    public static func inMemory() throws -> ItemStore { try ItemStore(memory: ()) }

    private init(memory: Void) throws {
        db = try SQLiteDatabase(path: ":memory:")
        try migrate()
    }

    private func migrate() throws {
        if db.userVersion < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE items (
                        id TEXT PRIMARY KEY,
                        sourceKind TEXT NOT NULL,
                        sourceID TEXT NOT NULL,
                        externalID TEXT,
                        title TEXT NOT NULL,
                        notes TEXT,
                        location TEXT,
                        start REAL NOT NULL,
                        end REAL,
                        isAllDay INTEGER NOT NULL,
                        status TEXT NOT NULL,
                        metadata TEXT NOT NULL,
                        updatedAt REAL NOT NULL
                    )
                    """)
                try db.execute("CREATE UNIQUE INDEX items_source_ext ON items(sourceID, externalID) WHERE externalID IS NOT NULL")
                try db.execute("CREATE INDEX items_start ON items(start)")
                try db.execute("CREATE TABLE subscriptions (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
                try db.setUserVersion(1)
            }
        }
        if db.userVersion < 2 {
            try db.transaction {
                // 整块保存的设置类数据（例如导入的课表），值是 JSON。
                try db.execute("CREATE TABLE documents (key TEXT PRIMARY KEY, json TEXT NOT NULL)")
                try db.setUserVersion(2)
            }
        }
    }

    // MARK: - 日程

    private static let overlapClause = "start < ? AND COALESCE(end, start) >= ?"

    public func items(in interval: DateInterval, statuses: Set<ItemStatus> = [.confirmed]) throws -> [CalendarItem] {
        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
        let args: [SQLValue] = [SQLValue(interval.end), SQLValue(interval.start)] + statuses.map { .text($0.rawValue) }
        return try db.query(
            "SELECT * FROM items WHERE \(Self.overlapClause) AND status IN (\(placeholders)) ORDER BY start",
            args
        ).compactMap(Self.decode)
    }

    public func pendingItems() throws -> [CalendarItem] {
        try db.query("SELECT * FROM items WHERE status = ? ORDER BY start", [.text(ItemStatus.pending.rawValue)])
            .compactMap(Self.decode)
    }

    public func item(id: UUID) throws -> CalendarItem? {
        try db.query("SELECT * FROM items WHERE id = ?", [.text(id.uuidString)]).first.flatMap(Self.decode)
    }

    public func save(_ item: CalendarItem) throws {
        try db.execute("""
            INSERT OR REPLACE INTO items
            (id, sourceKind, sourceID, externalID, title, notes, location, start, end, isAllDay, status, metadata, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, Self.encode(item))
    }

    public func setStatus(_ status: ItemStatus, for id: UUID) throws {
        try db.execute("UPDATE items SET status = ?, updatedAt = ? WHERE id = ?",
                       [.text(status.rawValue), SQLValue(Date.now), .text(id.uuidString)])
    }

    public func delete(id: UUID) throws {
        try db.execute("DELETE FROM items WHERE id = ?", [.text(id.uuidString)])
    }

    /// 某个来源的条目数；`prefix` 为 true 时匹配以 `sourceID` 开头的所有来源。
    public func itemCount(sourceID: String, prefix: Bool = false) throws -> Int {
        let match = prefix ? "\(sourceID)%" : sourceID
        return Int(try db.query("SELECT COUNT(*) AS n FROM items WHERE sourceID LIKE ?", [.text(match)]).first?.int("n") ?? 0)
    }

    /// 删除某个来源的全部条目，返回删除条数。
    @discardableResult
    public func deleteItems(sourceID: String, prefix: Bool = false) throws -> Int {
        let count = try itemCount(sourceID: sourceID, prefix: prefix)
        try db.execute("DELETE FROM items WHERE sourceID LIKE ?", [.text(prefix ? "\(sourceID)%" : sourceID)])
        return count
    }

    /// 用某个来源在 `range` 内的完整快照替换库中旧数据：
    /// 按 externalID 更新已有条目（保留原 id 和用户的忽略操作），插入新条目，删除快照中已消失的条目。
    public func replaceSnapshot(sourceID: String, in range: DateInterval, with items: [CalendarItem]) throws {
        try db.transaction {
            let existing = try db.query(
                "SELECT id, externalID, status FROM items WHERE sourceID = ? AND externalID IS NOT NULL AND \(Self.overlapClause)",
                [.text(sourceID), SQLValue(range.end), SQLValue(range.start)]
            )
            var known: [String: (id: String, status: String?)] = [:]
            for row in existing {
                if let ext = row.string("externalID"), let id = row.string("id") {
                    known[ext] = (id, row.string("status"))
                }
            }

            var seen = Set<String>()
            for var item in items {
                guard let ext = item.externalID else { continue }
                seen.insert(ext)
                if let old = known[ext] {
                    item.id = UUID(uuidString: old.id) ?? item.id
                    if old.status == ItemStatus.dismissed.rawValue { item.status = .dismissed }
                } else if let other = try db.query(
                    "SELECT id, status FROM items WHERE sourceID = ? AND externalID = ?", [.text(sourceID), .text(ext)]
                ).first {
                    // 条目原本在范围外（例如时间被改到范围内），沿用原 id。
                    item.id = other.string("id").flatMap(UUID.init(uuidString:)) ?? item.id
                }
                item.sourceID = sourceID
                try save(item)
            }

            for (ext, old) in known where !seen.contains(ext) {
                try db.execute("DELETE FROM items WHERE id = ?", [.text(old.id)])
            }
        }
    }

    /// 搜索标题、地点、备注和附加信息（取件码、车次等），按时间排序，最多 `limit` 条。
    public func search(_ query: String, limit: Int = 200) throws -> [CalendarItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        // 每个词都要出现在某个字段里；LIKE 的通配符要转义
        let clause = Array(repeating: "(title LIKE ? ESCAPE '\\' OR location LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\' OR metadata LIKE ? ESCAPE '\\')",
                           count: words.count).joined(separator: " AND ")
        let args: [SQLValue] = [.text(ItemStatus.confirmed.rawValue)] + words.flatMap { word -> [SQLValue] in
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return Array(repeating: .text("%\(escaped)%"), count: 4)
        } + [.int(Int64(limit))]
        return try db.query("SELECT * FROM items WHERE status = ? AND \(clause) ORDER BY start LIMIT ?", args)
            .compactMap(Self.decode)
    }

    /// 还没取的快递：最近 14 天短信识别出的取件条目，按收到时间倒序。
    public func pendingParcels(now: Date = .now) throws -> [CalendarItem] {
        try items(in: DateInterval(start: now.addingTimeInterval(-14 * 86400), end: now.addingTimeInterval(86400)))
            .filter(\.isParcelWithCode)
            .sorted { $0.start > $1.start }
    }

    // MARK: - 已取件队列

    /// 在小组件上点了「已取」：本地先隐藏，中转服务里的条目留给 App 下次同步时删除（小组件不能联网）。
    public func markParcelPickedLocally(id: UUID) throws {
        guard let item = try item(id: id) else { return }
        try setStatus(.dismissed, for: id)
        if let relayID = item.metadata["relayID"] {
            var queue = try document([String].self, key: "parcelPicks") ?? []
            if !queue.contains(relayID) { queue.append(relayID) }
            try saveDocument(queue, key: "parcelPicks")
        }
    }

    /// 取出并清空待通知中转服务的已取件 ID。
    public func takeParcelPicks() throws -> [String] {
        let queue = try document([String].self, key: "parcelPicks") ?? []
        if !queue.isEmpty { try saveDocument(Optional<[String]>.none, key: "parcelPicks") }
        return queue
    }

    /// 通知失败的放回队列，下次再试。
    public func requeueParcelPicks(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let queue = try document([String].self, key: "parcelPicks") ?? []
        try saveDocument(Array(Set(queue + ids)).sorted(), key: "parcelPicks")
    }

    // MARK: - 订阅

    public func subscriptions() throws -> [Subscription] {
        let decoder = JSONDecoder()
        return try db.query("SELECT json FROM subscriptions").compactMap { row in
            row.string("json").flatMap { try? decoder.decode(Subscription.self, from: Data($0.utf8)) }
        }.sorted { $0.name < $1.name }
    }

    public func save(_ subscription: Subscription) throws {
        let json = String(decoding: try JSONEncoder().encode(subscription), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO subscriptions (id, json) VALUES (?, ?)",
                       [.text(subscription.id.uuidString), .text(json)])
    }

    public func deleteSubscription(id: UUID) throws {
        try db.execute("DELETE FROM subscriptions WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - 课表

    public func courseSchedule() throws -> CourseSchedule? {
        try document(CourseSchedule.self, key: "courseSchedule")
    }

    public func saveCourseSchedule(_ schedule: CourseSchedule?) throws {
        try saveDocument(schedule, key: "courseSchedule")
    }

    private func document<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let json = try db.query("SELECT json FROM documents WHERE key = ?", [.text(key)]).first?.string("json")
        else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func saveDocument<T: Encodable>(_ value: T?, key: String) throws {
        guard let value else {
            try db.execute("DELETE FROM documents WHERE key = ?", [.text(key)])
            return
        }
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO documents (key, json) VALUES (?, ?)", [.text(key), .text(json)])
    }

    // MARK: - 编解码

    private static func encode(_ item: CalendarItem) -> [SQLValue] {
        let metadata = (try? JSONEncoder().encode(item.metadata)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [
            .text(item.id.uuidString), .text(item.sourceKind.rawValue), .text(item.sourceID), SQLValue(item.externalID),
            .text(item.title), SQLValue(item.notes), SQLValue(item.location), SQLValue(item.start), SQLValue(item.end),
            SQLValue(item.isAllDay), .text(item.status.rawValue), .text(metadata), SQLValue(item.updatedAt),
        ]
    }

    private static func decode(_ row: SQLRow) -> CalendarItem? {
        guard let id = row.string("id").flatMap(UUID.init(uuidString:)),
              let kind = row.string("sourceKind").flatMap(SourceKind.init(rawValue:)),
              let sourceID = row.string("sourceID"),
              let title = row.string("title"),
              let start = row.date("start"),
              let status = row.string("status").flatMap(ItemStatus.init(rawValue:))
        else { return nil }
        let metadata = row.string("metadata")
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        return CalendarItem(
            id: id, sourceKind: kind, sourceID: sourceID, externalID: row.string("externalID"),
            title: title, notes: row.string("notes"), location: row.string("location"),
            start: start, end: row.date("end"), isAllDay: row.int("isAllDay") == 1,
            status: status, metadata: metadata, updatedAt: row.date("updatedAt") ?? .now
        )
    }
}
