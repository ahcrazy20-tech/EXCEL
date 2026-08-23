import Foundation
import SQLite3

let SQLITE_TRANSIENT_HANDLE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: LocalizedError {
    case open(String)
    case exec(String)
    case prepare(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "DB open failed: \(m)"
        case .exec(let m): return "DB exec failed: \(m)"
        case .prepare(let m): return "DB prepare failed: \(m)"
        }
    }
}

/// Value coming back from SQLite.
enum DBValue: Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    var stringValue: String {
        switch self {
        case .null: return ""
        case .int(let v): return String(v)
        case .double(let v):
            if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
            return String(format: "%g", v)
        case .text(let s): return s
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .text(let s): return Double(s.replacingOccurrences(of: ",", with: ""))
        case .null: return nil
        }
    }

    var isNumeric: Bool { doubleValue != nil && !isEmptyText }

    var isEmptyText: Bool {
        if case .text(let s) = self { return s.trimmingCharacters(in: .whitespaces).isEmpty }
        if case .null = self { return true }
        return false
    }
}

/// Thin, fast wrapper around SQLite C API. All access is funnelled through a serial queue.
final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "sheetx.db")
    let path: String

    // Prepared-statement cache: page fetches / counts / filters reuse the same SQL
    // strings constantly, so preparing once and resetting is a significant win.
    private var stmtCache: [String: OpaquePointer] = [:]
    private var stmtKeys: [String] = []
    private let stmtCacheLimit = 64

    init(path: String) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &h, flags, nil) != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DBError.open(msg)
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA temp_store=MEMORY;")
        try exec("PRAGMA cache_size=-40000;")   // ~40MB page cache
        try exec("PRAGMA mmap_size=268435456;") // 256MB mmap
        try exec("PRAGMA wal_autocheckpoint=1000;")
        try exec("PRAGMA busy_timeout=5000;")
    }

    deinit {
        // Finalize cached statements before closing so nothing is orphaned.
        for stmt in stmtCache.values { sqlite3_finalize(stmt) }
        stmtCache.removeAll()
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        guard let handle else { return "no handle" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func exec(_ sql: String) throws {
        try queue.sync {
            if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
                throw DBError.exec("\(errorMessage) — SQL: \(sql.prefix(300))")
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [DBValue] = []) throws -> Int {
        try queue.sync {
            let stmt = try cachedStmt(sql, params)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DBError.exec("\(errorMessage) — SQL: \(sql.prefix(300))")
            }
            return Int(sqlite3_changes(handle))
        }
    }

    func lastInsertRowID() -> Int64 {
        queue.sync { sqlite3_last_insert_rowid(handle) }
    }

    func query(_ sql: String, _ params: [DBValue] = []) throws -> [[DBValue]] {
        try queue.sync {
            let stmt = try cachedStmt(sql, params)
            var rows: [[DBValue]] = []
            let cols = Int(sqlite3_column_count(stmt))
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [DBValue] = []
                row.reserveCapacity(cols)
                for i in 0..<cols { row.append(Database.value(stmt, Int32(i))) }
                rows.append(row)
            }
            return rows
        }
    }

    func scalar(_ sql: String, _ params: [DBValue] = []) throws -> DBValue {
        let rows = try query(sql, params)
        return rows.first?.first ?? .null
    }

    func columnNames(_ sql: String, _ params: [DBValue] = []) throws -> [String] {
        try queue.sync {
            let stmt = try cachedStmt(sql, params)
            let cols = Int(sqlite3_column_count(stmt))
            return (0..<cols).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        }
    }

    /// Bulk insert helper: prepares once, steps many times inside one transaction.
    func bulkInsert(sql: String, rows: () throws -> [DBValue]?) throws {
        try queue.sync {
            if sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
                throw DBError.exec(errorMessage)
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw DBError.prepare(errorMessage)
            }
            defer { sqlite3_finalize(stmt) }
            do {
                while let values = try rows() {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    Database.bind(stmt, values)
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        throw DBError.exec(errorMessage)
                    }
                }
            } catch {
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw error
            }
            if sqlite3_exec(handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                throw DBError.exec(errorMessage)
            }
        }
    }

    /// A reusable prepared statement for high-throughput import.
    final class Inserter {
        fileprivate let db: Database
        fileprivate var stmt: OpaquePointer?
        fileprivate var open = false

        init(db: Database, sql: String) throws {
            self.db = db
            try db.queue.sync {
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db.handle, sql, -1, &s, nil) == SQLITE_OK else {
                    throw DBError.prepare(db.errorMessage)
                }
                stmt = s
            }
        }

        func begin() throws {
            try db.queue.sync {
                guard !open else { return }
                if sqlite3_exec(db.handle, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
                    throw DBError.exec(db.errorMessage)
                }
                open = true
            }
        }

        func insert(_ values: [DBValue]) throws {
            try db.queue.sync {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                Database.bind(stmt, values)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw DBError.exec(db.errorMessage)
                }
            }
        }

        func commit() throws {
            try db.queue.sync {
                guard open else { return }
                if sqlite3_exec(db.handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    throw DBError.exec(db.errorMessage)
                }
                open = false
            }
        }

        func finish() {
            try? commit()
            db.queue.sync {
                if let stmt { sqlite3_finalize(stmt) }
                stmt = nil
            }
        }
    }

    func makeInserter(_ sql: String) throws -> Inserter { try Inserter(db: self, sql: sql) }

    // MARK: - private

    /// Returns a reset, bound statement from the cache (or prepares and caches it).
    /// Must only be called on the serial queue.
    private func cachedStmt(_ sql: String, _ params: [DBValue]) throws -> OpaquePointer? {
        let stmt: OpaquePointer?
        if let cached = stmtCache[sql] {
            sqlite3_reset(cached)
            stmt = cached
        } else {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK else {
                throw DBError.prepare("\(errorMessage) — SQL: \(sql.prefix(300))")
            }
            stmt = s
            if stmtKeys.count >= stmtCacheLimit, let oldest = stmtKeys.first {
                stmtKeys.removeFirst()
                if let evicted = stmtCache.removeValue(forKey: oldest) {
                    sqlite3_finalize(evicted)
                }
            }
            stmtCache[sql] = stmt
            stmtKeys.append(sql)
        }
        sqlite3_clear_bindings(stmt)
        Database.bind(stmt, params)
        return stmt
    }

    fileprivate static func bind(_ stmt: OpaquePointer?, _ params: [DBValue]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_HANDLE)
            }
        }
    }

    fileprivate static func value(_ stmt: OpaquePointer?, _ i: Int32) -> DBValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        default:
            if let c = sqlite3_column_text(stmt, i) { return .text(String(cString: c)) }
            return .null
        }
    }
}

extension String {
    /// Escapes an identifier for safe interpolation into SQL.
    var sqlIdentifier: String { "\"" + replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    /// Escapes a string literal for safe interpolation into SQL.
    var sqlLiteral: String { "'" + replacingOccurrences(of: "'", with: "''") + "'" }
}
