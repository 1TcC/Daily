import Foundation
import SQLite3

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    public var description: String {
        switch self {
        case .open(let msg): "SQLite open failed: \(msg)"
        case .prepare(let msg, let sql): "SQLite prepare failed: \(msg) — \(sql)"
        case .step(let msg, let sql): "SQLite step failed: \(msg) — \(sql)"
        }
    }
}

enum SQLValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null

    init(_ string: String?) { self = string.map(SQLValue.text) ?? .null }
    init(_ date: Date?) { self = date.map { .double($0.timeIntervalSince1970) } ?? .null }
    init(_ bool: Bool) { self = .int(bool ? 1 : 0) }
}

struct SQLRow {
    fileprivate var values: [String: SQLValue]

    func string(_ column: String) -> String? {
        if case .text(let s) = values[column] { return s }
        return nil
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }

    func int(_ column: String) -> Int64? {
        switch values[column] {
        case .int(let i): i
        case .double(let d): Int64(d)
        default: nil
        }
    }

    func date(_ column: String) -> Date? { double(column).map(Date.init(timeIntervalSince1970:)) }
}

/// 极简 SQLite 封装。递归锁保证线程安全（事务内可嵌套调用），
/// WAL 模式让 App 写入、Widget 读取可以并发进行。
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.open(msg)
        }
        sqlite3_busy_timeout(handle, 2000)
        if path != ":memory:" { try execute("PRAGMA journal_mode=WAL") }
    }

    deinit { sqlite3_close(handle) }

    var userVersion: Int {
        guard let row = try? query("PRAGMA user_version").first, let v = row.int("user_version") else { return 0 }
        return Int(v)
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    func execute(_ sql: String, _ args: [SQLValue] = []) throws {
        _ = try run(sql, args, collect: false)
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLRow] {
        try run(sql, args, collect: true)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ args: [SQLValue], collect: Bool) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(errorMessage, sql: sql) }
            guard collect else { continue }
            var values: [String: SQLValue] = [:]
            for col in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, col))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, col)))
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}
