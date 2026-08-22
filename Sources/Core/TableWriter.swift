import Foundation

/// Creates and fills a data table, growing the column count on demand.
/// Designed for millions of rows: one prepared statement, batched transactions.
final class TableWriter {
    private let db: Database
    private let tableName: String
    private var columnCount: Int
    private var inserter: Database.Inserter?
    private var pending = 0
    private(set) var rowCount = 0
    private let batchSize: Int

    init(db: Database, tableName: String, columnCount: Int, batchSize: Int = 20_000) throws {
        self.db = db
        self.tableName = tableName
        self.columnCount = max(1, columnCount)
        self.batchSize = batchSize
        try db.exec("DROP TABLE IF EXISTS \(tableName.sqlIdentifier);")
        let cols = (0..<self.columnCount).map { "c\($0) NUMERIC" }.joined(separator: ",")
        try db.exec("CREATE TABLE \(tableName.sqlIdentifier)(\(cols));")
        try prepare()
    }

    private func prepare() throws {
        let names = (0..<columnCount).map { "c\($0)" }.joined(separator: ",")
        let marks = Array(repeating: "?", count: columnCount).joined(separator: ",")
        inserter = try db.makeInserter("INSERT INTO \(tableName.sqlIdentifier)(\(names)) VALUES(\(marks))")
        try inserter?.begin()
    }

    private func grow(to newCount: Int) throws {
        guard newCount > columnCount else { return }
        inserter?.finish()
        inserter = nil
        for i in columnCount..<newCount {
            try db.exec("ALTER TABLE \(tableName.sqlIdentifier) ADD COLUMN c\(i) NUMERIC;")
        }
        columnCount = newCount
        try prepare()
    }

    func write(_ row: [DBValue]) throws {
        if row.count > columnCount { try grow(to: row.count) }
        var values = row
        if values.count < columnCount {
            values.append(contentsOf: Array(repeating: DBValue.null, count: columnCount - values.count))
        }
        try inserter?.insert(values)
        rowCount += 1
        pending += 1
        if pending >= batchSize {
            try inserter?.commit()
            try inserter?.begin()
            pending = 0
        }
    }

    @discardableResult
    func finish() throws -> Int {
        try inserter?.commit()
        inserter?.finish()
        inserter = nil
        return rowCount
    }

    var currentColumnCount: Int { columnCount }
}

enum ValueCoercion {
    /// Turns a raw string into the tightest DBValue (fast path for CSV/text import).
    static func fromString(_ s: String) -> DBValue {
        if s.isEmpty { return .null }
        let first = s.utf8.first!
        // Only try numeric parsing when it plausibly starts like a number.
        if (first >= 48 && first <= 57) || first == 45 || first == 43 || first == 46 {
            // Keep IDs / phone numbers with leading zeros as text.
            if first == 48 && s.count > 1 && !s.hasPrefix("0.") { return .text(s) }
            if s.count < 19, !s.contains(" "), let i = Int64(s) { return .int(i) }
            if let d = Double(s), d.isFinite { return .double(d) }
        }
        return .text(s)
    }
}
