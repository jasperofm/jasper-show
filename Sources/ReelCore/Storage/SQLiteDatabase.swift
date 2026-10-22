import Foundation
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String)
    case bind(String)

    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open database: \(m)"
        case .prepare(let m, let sql): return "SQL prepare failed (\(m)): \(sql)"
        case .step(let m): return "SQL step failed: \(m)"
        case .bind(let m): return "SQL bind failed: \(m)"
        }
    }
}

/// Values that can be bound to a statement parameter.
public enum SQLValue {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension UUID: SQLBindable { public var sqlValue: SQLValue { .text(uuidString) } }
/// Dates are stored as Unix seconds (REAL) so they sort and compare in SQL.
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// One result row with typed column access by name.
public struct Row {
    fileprivate let stmt: OpaquePointer
    fileprivate let columns: [String: Int32]

    private func idx(_ name: String) -> Int32 {
        guard let i = columns[name] else { preconditionFailure("No column \(name)") }
        return i
    }
    public func isNull(_ name: String) -> Bool { sqlite3_column_type(stmt, idx(name)) == SQLITE_NULL }
    public func int(_ name: String) -> Int { Int(sqlite3_column_int64(stmt, idx(name))) }
    public func int64(_ name: String) -> Int64 { sqlite3_column_int64(stmt, idx(name)) }
    public func double(_ name: String) -> Double { sqlite3_column_double(stmt, idx(name)) }
    public func bool(_ name: String) -> Bool { int(name) != 0 }
    public func string(_ name: String) -> String {
        guard let c = sqlite3_column_text(stmt, idx(name)) else { return "" }
        return String(cString: c)
    }
    public func optString(_ name: String) -> String? { isNull(name) ? nil : string(name) }
    public func optInt(_ name: String) -> Int? { isNull(name) ? nil : int(name) }
    public func uuid(_ name: String) -> UUID { UUID(uuidString: string(name))! }
    public func optUUID(_ name: String) -> UUID? { optString(name).flatMap(UUID.init(uuidString:)) }
    public func date(_ name: String) -> Date { Date(timeIntervalSince1970: double(name)) }
    public func optDate(_ name: String) -> Date? { isNull(name) ? nil : date(name) }
    public func data(_ name: String) -> Data {
        let i = idx(name)
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Thin, serialized wrapper over the SQLite C API. All access goes through a
/// private serial queue, so it is safe to call from any thread or task.
public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "ReelCore.SQLite")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `path == nil` opens an in-memory database (tests).
    public init(path: String?) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(msg)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more statements with no parameters and no results.
    public func execute(_ sql: String) throws {
        try queue.sync {
            if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw DatabaseError.step(lastError) }
        }
    }

    /// Runs a single statement with parameters. Returns rows changed.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLBindable] = []) throws -> Int {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DatabaseError.step(lastError) }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query<T>(_ sql: String, _ params: [SQLBindable] = [], map: (Row) throws -> T) throws -> [T] {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var cols: [String: Int32] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                cols[String(cString: sqlite3_column_name(stmt, i))] = i
            }
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DatabaseError.step(lastError) }
                out.append(try map(Row(stmt: stmt, columns: cols)))
            }
            return out
        }
    }

    /// Runs an INSERT and returns its rowid, atomically with respect to other callers.
    public func insert(_ sql: String, _ params: [SQLBindable] = []) throws -> Int64 {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.step(lastError) }
            return sqlite3_last_insert_rowid(handle)
        }
    }

    /// Runs `body` inside BEGIN/COMMIT, rolling back on throw. Statements in
    /// `body` go through `run`/`query` as usual.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(lastError, sql: sql)
        }
        for (i, p) in params.enumerated() {
            let pos = Int32(i + 1)
            let rc: Int32
            switch p.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, pos)
            case .int(let v): rc = sqlite3_bind_int64(stmt, pos, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, pos, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, pos, v, -1, Self.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, pos, $0.baseAddress, Int32(v.count), Self.transient) }
            }
            if rc != SQLITE_OK { sqlite3_finalize(stmt); throw DatabaseError.bind(lastError) }
        }
        return stmt
    }
}
