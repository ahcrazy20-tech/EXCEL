import Foundation
import SQLite3

/// A job owns this token, never the shared workspace connection. Cancelling an
/// analysis therefore cannot interrupt imports or interactive grid reads.
final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum AnalysisError: LocalizedError {
    case readOnly, multipleStatements, timedOut, resultTooLarge, invalidPlan, incompatibleRecipe
    var errorDescription: String? {
        switch self {
        case .readOnly: return "analysis.readOnly".loc
        case .multipleStatements: return "analysis.oneStatement".loc
        case .timedOut: return "analysis.timedOut".loc
        case .resultTooLarge: return "analysis.tooLarge".loc
        case .invalidPlan: return "analysis.invalidPlan".loc
        case .incompatibleRecipe: return "analysis.incompatible".loc
        }
    }
}

/// Lifetime matches one read-only connection. Budget spans all statements in a
/// job, not just each individual SQL call. All fields except the token are immutable.
final class AnalysisQueryPolicy {
    let tableName: String
    let cancellation: QueryCancellation
    let maxRows: Int
    let maxBytes: Int
    private let deadline: TimeInterval

    init(tableName: String, cancellation: QueryCancellation = QueryCancellation(),
         timeout: TimeInterval = 15, maxRows: Int = 10_000, maxBytes: Int = 4 * 1024 * 1024) {
        self.tableName = tableName
        self.cancellation = cancellation
        self.deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        self.maxRows = max(1, maxRows)
        self.maxBytes = max(1, maxBytes)
    }

    func check() throws {
        if cancellation.isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw AnalysisError.timedOut }
    }

    func install(on handle: OpaquePointer?) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_progress_handler(handle, 1000, { context in
            guard let context else { return 1 }
            let policy = Unmanaged<AnalysisQueryPolicy>.fromOpaque(context).takeUnretainedValue()
            do { try policy.check(); return 0 } catch { return 1 }
        }, context)
        sqlite3_set_authorizer(handle, { context, action, first, second, database, _ in
            guard let context else { return SQLITE_DENY }
            let policy = Unmanaged<AnalysisQueryPolicy>.fromOpaque(context).takeUnretainedValue()
            switch action {
            case SQLITE_SELECT, SQLITE_RECURSIVE:
                return SQLITE_OK
            case SQLITE_READ:
                let table = first.map { String(cString: $0) } ?? ""
                let schema = database.map { String(cString: $0) } ?? ""
                return (schema == "main" && table == policy.tableName)
                    || (schema == "temp" && table == "data") ? SQLITE_OK : SQLITE_DENY
            case SQLITE_FUNCTION:
                let name = second.map { String(cString: $0).lowercased() } ?? ""
                return AnalysisQueryPolicy.functions.contains(name) ? SQLITE_OK : SQLITE_DENY
            default:
                // Deny schema writes, transactions, PRAGMAs, ATTACH, extensions,
                // metadata access, and writes even to temporary tables.
                return SQLITE_DENY
            }
        }, context)
    }

    private static let functions: Set<String> = [
        "abs", "avg", "count", "min", "max", "sum", "total", "round", "sqrt", "pow", "power",
        "coalesce", "nullif", "ifnull", "iif", "trim", "ltrim", "rtrim", "length", "lower", "upper",
        "substr", "substring", "replace", "instr", "like", "glob", "typeof", "date", "time", "datetime",
        "julianday", "strftime", "unixepoch", "printf", "format", "unicode", "char", "group_concat",
        "row_number", "rank", "dense_rank", "lag", "lead", "first_value", "last_value", "nth_value",
        "ntile", "percent_rank", "cume_dist"
    ]
}
