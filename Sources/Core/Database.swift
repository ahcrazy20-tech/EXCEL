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
    private let queueKey = DispatchSpecificKey<Bool>()
    let path: String
    let analysisPolicy: AnalysisQueryPolicy?

    // Prepared-statement cache: page fetches / counts / filters reuse the same SQL
    // strings constantly, so preparing once and resetting is a significant win.
    private var stmtCache: [String: OpaquePointer] = [:]
    private var stmtKeys: [String] = []
    private let stmtCacheLimit = 64

    init(path: String, analysisPolicy: AnalysisQueryPolicy? = nil) throws {
        self.path = path
        self.analysisPolicy = analysisPolicy
        queue.setSpecific(key: queueKey, value: true)
        var h: OpaquePointer?
        let flags = analysisPolicy == nil
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &h, flags, nil) != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h { sqlite3_close_v2(h) }
            throw DBError.open(msg)
        }
        handle = h
        do {
            if let policy = analysisPolicy {
                try policy.check()
                sqlite3_busy_timeout(handle, 100)
                sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
                sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 100_000)
                sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 256)
                sqlite3_limit(handle, SQLITE_LIMIT_EXPR_DEPTH, 100)
                sqlite3_limit(handle, SQLITE_LIMIT_COMPOUND_SELECT, 20)
                try exec("PRAGMA cache_size=-8000;")
                // The local alias avoids text replacement inside SQL literals/comments.
                try exec("CREATE TEMP VIEW data AS SELECT rowid AS rowid,* FROM main.\(policy.tableName.sqlIdentifier);")
                try exec("PRAGMA query_only=ON;")
                try exec("BEGIN;") // one consistent read snapshot for multi-statement profiling
                policy.install(on: handle)
            } else {
                try exec("PRAGMA journal_mode=WAL;")
                try exec("PRAGMA synchronous=NORMAL;")
                try exec("PRAGMA temp_store=MEMORY;")
                try exec("PRAGMA cache_size=-40000;")
                try exec("PRAGMA mmap_size=268435456;")
                try exec("PRAGMA wal_autocheckpoint=1000;")
                try exec("PRAGMA busy_timeout=5000;")
            }
        } catch {
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
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

    /// Re-entrant only on this database's queue, so a transaction can use the
    /// ordinary helpers without deadlocking or allowing other work to interleave.
    private func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try synchronized {
            guard analysisPolicy == nil else { throw AnalysisError.readOnly }
            guard sqlite3_get_autocommit(handle) != 0 else {
                throw DBError.exec("files.storageBusy".loc)
            }
            clearStatementCache()
            try exec("BEGIN IMMEDIATE;")
            defer { clearStatementCache() }
            do {
                let value = try work()
                try exec("COMMIT;")
                return value
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    private func clearStatementCache() {
        for statement in stmtCache.values { sqlite3_finalize(statement) }
        stmtCache.removeAll()
        stmtKeys.removeAll()
    }

    func exec(_ sql: String) throws {
        try synchronized {
            if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
                throw DBError.exec("\(errorMessage) — SQL: \(sql.prefix(300))")
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [DBValue] = []) throws -> Int {
        try synchronized {
            let stmt = try cachedStmt(sql, params)
            defer { sqlite3_reset(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DBError.exec("\(errorMessage) — SQL: \(sql.prefix(300))")
            }
            return Int(sqlite3_changes(handle))
        }
    }

    func lastInsertRowID() -> Int64 {
        synchronized { sqlite3_last_insert_rowid(handle) }
    }

    func query(_ sql: String, _ params: [DBValue] = []) throws -> [[DBValue]] {
        try readResult(sql, params, truncate: false).rows
    }

    /// Bounded previews are allowed only on isolated analysis connections. Internal
    /// queries throw on overflow instead of silently returning misleading statistics.
    func readResult(_ sql: String, _ params: [DBValue] = [],
                    limit: Int? = nil, truncate: Bool = true) throws -> ResultTable {
        try synchronized {
            try analysisPolicy?.check()
            let stmt = try cachedStmt(sql, params)
            defer { sqlite3_reset(stmt) }
            let cols = Int(sqlite3_column_count(stmt))
            let names = (0..<cols).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
            let cap = min(limit ?? Int.max, analysisPolicy?.maxRows ?? Int.max)
            let byteCap = analysisPolicy?.maxBytes ?? Int.max
            var bytes = 0
            var rows: [[DBValue]] = []
            var truncated = false
            while true {
                try analysisPolicy?.check()
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    try analysisPolicy?.check()
                    throw DBError.exec(errorMessage)
                }
                let rowBytes = (0..<cols).reduce(0) { size, index in
                    let type = sqlite3_column_type(stmt, Int32(index))
                    return size + 32 + (type == SQLITE_TEXT || type == SQLITE_BLOB
                        ? Int(sqlite3_column_bytes(stmt, Int32(index))) : 8)
                }
                if rows.count >= cap || rowBytes > byteCap - bytes {
                    guard truncate, !rows.isEmpty else { throw AnalysisError.resultTooLarge }
                    truncated = true
                    break
                }
                bytes += rowBytes
                rows.append((0..<cols).map { Database.value(stmt, Int32($0)) })
            }
            return ResultTable(columns: names, rows: rows, truncated: truncated)
        }
    }

    func scalar(_ sql: String, _ params: [DBValue] = []) throws -> DBValue {
        let rows = try query(sql, params)
        return rows.first?.first ?? .null
    }

    func columnNames(_ sql: String, _ params: [DBValue] = []) throws -> [String] {
        try synchronized {
            let stmt = try cachedStmt(sql, params)
            defer { sqlite3_reset(stmt) }
            let cols = Int(sqlite3_column_count(stmt))
            return (0..<cols).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        }
    }

    /// Bulk insert helper: prepares once, steps many times inside one transaction.
    func bulkInsert(sql: String, rows: () throws -> [DBValue]?) throws {
        try synchronized {
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
            try db.synchronized {
                var s: OpaquePointer?
                guard sqlite3_prepare_v2(db.handle, sql, -1, &s, nil) == SQLITE_OK else {
                    throw DBError.prepare(db.errorMessage)
                }
                stmt = s
            }
        }

        func begin() throws {
            try db.synchronized {
                guard !open else { return }
                if sqlite3_exec(db.handle, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
                    throw DBError.exec(db.errorMessage)
                }
                open = true
            }
        }

        func insert(_ values: [DBValue]) throws {
            try db.synchronized {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                Database.bind(stmt, values)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    throw DBError.exec(db.errorMessage)
                }
            }
        }

        func commit() throws {
            try db.synchronized {
                guard open else { return }
                if sqlite3_exec(db.handle, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    throw DBError.exec(db.errorMessage)
                }
                open = false
            }
        }

        func finish() {
            try? commit()
            db.synchronized {
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
            do {
                try sql.withCString { text in
                    var tail: UnsafePointer<CChar>?
                    guard sqlite3_prepare_v2(handle, text, -1, &s, &tail) == SQLITE_OK, s != nil else {
                        try analysisPolicy?.check()
                        throw DBError.prepare(errorMessage)
                    }
                    if analysisPolicy != nil {
                        guard sqlite3_stmt_readonly(s) != 0 else { throw AnalysisError.readOnly }
                        // Ask SQLite to parse the tail: semicolons in strings and trailing
                        // comments are safe, a second statement (even SELECT) is not.
                        while let rest = tail, rest.pointee != 0 {
                            var extra: OpaquePointer?
                            var next: UnsafePointer<CChar>?
                            let rc = sqlite3_prepare_v2(handle, rest, -1, &extra, &next)
                            let hasExtra = extra != nil
                            sqlite3_finalize(extra)
                            guard rc == SQLITE_OK, !hasExtra else { throw AnalysisError.multipleStatements }
                            if next == rest { break }
                            tail = next
                        }
                    }
                }
            } catch {
                sqlite3_finalize(s)
                throw error
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
