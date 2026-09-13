import Foundation

// MARK: - Filters

enum FilterOperator: String, Codable, CaseIterable, Identifiable {
    case equals, notEquals, contains, notContains, startsWith, endsWith
    case greaterThan, greaterOrEqual, lessThan, lessOrEqual, between
    case isEmpty, notEmpty, inList, regex

    var id: String { rawValue }

    var needsValue: Bool {
        switch self {
        case .isEmpty, .notEmpty: return false
        default: return true
        }
    }

    var needsSecondValue: Bool { self == .between }

    var display: String {
        switch self {
        case .equals: return "="
        case .notEquals: return "≠"
        case .contains: return "contains"
        case .notContains: return "not contains"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .greaterThan: return ">"
        case .greaterOrEqual: return "≥"
        case .lessThan: return "<"
        case .lessOrEqual: return "≤"
        case .between: return "between"
        case .isEmpty: return "is empty"
        case .notEmpty: return "not empty"
        case .inList: return "in list"
        case .regex: return "matches"
        }
    }
}

struct FilterCondition: Identifiable, Codable, Hashable {
    var id = UUID()
    var columnIndex: Int
    var op: FilterOperator = .contains
    var value: String = ""
    var value2: String = ""
}

enum FilterJoin: String, Codable { case and, or }

struct SortSpec: Identifiable, Codable, Hashable {
    var id = UUID()
    var columnIndex: Int
    var ascending: Bool = true
}

struct QuerySpec: Codable, Hashable {
    var search: String = ""
    var searchColumns: [Int] = []      // empty = all columns
    var filters: [FilterCondition] = []
    var join: FilterJoin = .and
    var sorts: [SortSpec] = []
    var distinctColumns: [Int] = []

    var isActive: Bool { !search.isEmpty || !filters.isEmpty || !sorts.isEmpty || !distinctColumns.isEmpty }
}

// MARK: - Aggregation

enum AggFunction: String, Codable, CaseIterable, Identifiable {
    case count, countDistinct, sum, avg, min, max, median, stdev

    var id: String { rawValue }
    var display: String {
        switch self {
        case .count: return "COUNT"
        case .countDistinct: return "COUNT DISTINCT"
        case .sum: return "SUM"
        case .avg: return "AVG"
        case .min: return "MIN"
        case .max: return "MAX"
        case .median: return "MEDIAN"
        case .stdev: return "STDEV"
        }
    }
    var needsColumn: Bool { self != .count }
}

struct Aggregation: Identifiable, Codable, Hashable {
    var id = UUID()
    var function: AggFunction
    var columnIndex: Int?
    var alias: String?
}

struct AnalysisSpec: Codable, Hashable {
    var query = QuerySpec()
    var groupBy: [Int] = []
    var aggregations: [Aggregation] = []
    var sortByResultColumn: Int?      // index within output columns
    var sortDescending = true
    var limit: Int = 50
}

struct ResultTable {
    var columns: [String]
    var rows: [[DBValue]]
    var truncated: Bool = false

    var isEmpty: Bool { rows.isEmpty }
}

// MARK: - Engine

final class QueryEngine: @unchecked Sendable {
    let db: Database
    let sheet: SheetInfo

    init(db: Database, sheet: SheetInfo) {
        self.db = db
        self.sheet = sheet
    }

    private func column(_ index: Int) -> String? {
        guard index >= 0, index < sheet.columns.count else { return nil }
        return "c\(index)"
    }

    func columnName(_ index: Int) -> String {
        guard index >= 0, index < sheet.columns.count else { return "c\(index)" }
        return sheet.columns[index].name
    }

    /// Builds a WHERE clause (without the WHERE keyword). Values are bound, never interpolated.
    func whereClause(_ spec: QuerySpec) -> (String, [DBValue]) {
        var clauses: [String] = []
        var params: [DBValue] = []

        for f in spec.filters {
            guard let col = column(f.columnIndex) else { continue }
            let isNumericCol = sheet.columns[f.columnIndex].kind == .number
            switch f.op {
            case .equals:
                if isNumericCol, let d = Double(f.value) {
                    clauses.append("CAST(\(col) AS REAL) = ?"); params.append(.double(d))
                } else {
                    clauses.append("CAST(\(col) AS TEXT) = ? COLLATE NOCASE"); params.append(.text(f.value))
                }
            case .notEquals:
                clauses.append("IFNULL(CAST(\(col) AS TEXT),'') <> ? COLLATE NOCASE"); params.append(.text(f.value))
            case .contains:
                clauses.append("CAST(\(col) AS TEXT) LIKE ? ESCAPE '\\'"); params.append(.text("%\(escapeLike(f.value))%"))
            case .notContains:
                clauses.append("IFNULL(CAST(\(col) AS TEXT),'') NOT LIKE ? ESCAPE '\\'"); params.append(.text("%\(escapeLike(f.value))%"))
            case .startsWith:
                clauses.append("CAST(\(col) AS TEXT) LIKE ? ESCAPE '\\'"); params.append(.text("\(escapeLike(f.value))%"))
            case .endsWith:
                clauses.append("CAST(\(col) AS TEXT) LIKE ? ESCAPE '\\'"); params.append(.text("%\(escapeLike(f.value))"))
            case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
                let opSym = ["greaterThan": ">", "greaterOrEqual": ">=", "lessThan": "<", "lessOrEqual": "<="][f.op.rawValue] ?? ">"
                if let d = Double(f.value) {
                    clauses.append("CAST(\(col) AS REAL) \(opSym) ?"); params.append(.double(d))
                } else {
                    clauses.append("CAST(\(col) AS TEXT) \(opSym) ?"); params.append(.text(f.value))
                }
            case .between:
                if let a = Double(f.value), let b = Double(f.value2) {
                    clauses.append("CAST(\(col) AS REAL) BETWEEN ? AND ?")
                    params.append(.double(min(a, b))); params.append(.double(max(a, b)))
                } else {
                    clauses.append("CAST(\(col) AS TEXT) BETWEEN ? AND ?")
                    params.append(.text(f.value)); params.append(.text(f.value2))
                }
            case .isEmpty:
                clauses.append("(\(col) IS NULL OR TRIM(CAST(\(col) AS TEXT))='')")
            case .notEmpty:
                clauses.append("(\(col) IS NOT NULL AND TRIM(CAST(\(col) AS TEXT))<>'')")
            case .inList:
                let parts = f.value.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "،" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.isEmpty { continue }
                let marks = Array(repeating: "?", count: parts.count).joined(separator: ",")
                clauses.append("CAST(\(col) AS TEXT) COLLATE NOCASE IN (\(marks))")
                params.append(contentsOf: parts.map { DBValue.text($0) })
            case .regex:
                // SQLite has no REGEXP by default: approximate with GLOB.
                clauses.append("CAST(\(col) AS TEXT) GLOB ?"); params.append(.text(f.value))
            }
        }

        var whereSQL = clauses.isEmpty ? "" : "(" + clauses.joined(separator: spec.join == .and ? " AND " : " OR ") + ")"

        let term = spec.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let cols = spec.searchColumns.isEmpty ? sheet.columns.map { $0.index } : spec.searchColumns
            let likes = cols.compactMap { column($0) }.map { "IFNULL(CAST(\($0) AS TEXT),'') LIKE ? ESCAPE '\\'" }
            if !likes.isEmpty {
                let searchSQL = "(" + likes.joined(separator: " OR ") + ")"
                for _ in likes { params.append(.text("%\(escapeLike(term))%")) }
                whereSQL = whereSQL.isEmpty ? searchSQL : "\(whereSQL) AND \(searchSQL)"
            }
        }
        return (whereSQL, params)
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    func orderClause(_ spec: QuerySpec) -> String {
        let parts: [String] = spec.sorts.compactMap { s in
            guard let col = column(s.columnIndex) else { return nil }
            let kind = sheet.columns[s.columnIndex].kind
            let expr = kind == .number ? "CAST(\(col) AS REAL)" : col
            return "\(expr) \(s.ascending ? "ASC" : "DESC")"
        }
        return parts.isEmpty ? "" : "ORDER BY " + parts.joined(separator: ", ")
    }

    // MARK: Row access

    // Qualify the source: SQLite may omit the database in its authorizer callback
    // for an unqualified, optimized COUNT(*). Keep the strict authorizer unchanged.
    func countRows(_ spec: QuerySpec) throws -> Int {
        let (w, p) = whereClause(spec)
        let sql = "SELECT COUNT(*) FROM main.\(sheet.tableName.sqlIdentifier)" + (w.isEmpty ? "" : " WHERE \(w)")
        return Int(try db.scalar(sql, p).doubleValue ?? 0)
    }

    func fetchRows(_ spec: QuerySpec, offset: Int, limit: Int) throws -> [[DBValue]] {
        let cols = sheet.columns.map { "c\($0.index)" }.joined(separator: ",")
        // Fast path: with no filters/sorts the table's rowids are contiguous (1…N),
        // so a page is a direct range seek instead of scanning past OFFSET rows.
        // Jumping to row 1,000,000 becomes instant.
        if !spec.isActive {
            let sql = "SELECT rowid,\(cols) FROM main.\(sheet.tableName.sqlIdentifier) WHERE rowid >= ? AND rowid < ?"
            return try db.query(sql, [.int(Int64(offset + 1)), .int(Int64(offset + limit + 1))])
        }
        let (w, p) = whereClause(spec)
        var sql = "SELECT rowid,\(cols) FROM main.\(sheet.tableName.sqlIdentifier)"
        if !w.isEmpty { sql += " WHERE \(w)" }
        let order = orderClause(spec)
        if !order.isEmpty { sql += " \(order)" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return try db.query(sql, p)
    }

    func fetchRow(rowid: Int64) throws -> [DBValue]? {
        let cols = sheet.columns.map { "c\($0.index)" }.joined(separator: ",")
        return try db.query("SELECT \(cols) FROM main.\(sheet.tableName.sqlIdentifier) WHERE rowid=?", [.int(rowid)]).first
    }

    /// Fetches the stored fill-colour strings (`"col:argb;col:argb"`) for the given
    /// data rowids, keyed by rowid. Returns an empty map when the sheet has no colours.
    func fetchFills(rowids: [Int64]) throws -> [Int64: String] {
        guard sheet.hasColors, !rowids.isEmpty else { return [:] }
        var out: [Int64: String] = [:]
        out.reserveCapacity(rowids.count)
        let table = sheet.fillsTableName.sqlIdentifier
        var start = 0
        while start < rowids.count {
            let chunk = rowids[start..<min(start + 400, rowids.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("SELECT rowid,f FROM \(table) WHERE rowid IN (\(marks))",
                                    chunk.map { DBValue.int($0) })
            for r in rows {
                guard case .int(let id) = r[0] else { continue }
                out[id] = r[1].stringValue
            }
            start += chunk.count
        }
        return out
    }

    // MARK: Aggregation

    func aggregateExpression(_ agg: Aggregation) -> String {
        guard let idx = agg.columnIndex, let col = column(idx) else { return "COUNT(*)" }
        let numeric = "CAST(REPLACE(CAST(\(col) AS TEXT),',','') AS REAL)"
        switch agg.function {
        case .count: return "COUNT(*)"
        case .countDistinct: return "COUNT(DISTINCT \(col))"
        case .sum: return "SUM(\(numeric))"
        case .avg: return "AVG(\(numeric))"
        case .min: return sheet.columns[idx].kind == .number ? "MIN(\(numeric))" : "MIN(\(col))"
        case .max: return sheet.columns[idx].kind == .number ? "MAX(\(numeric))" : "MAX(\(col))"
        case .median: return "AVG(\(numeric))"   // replaced by exact median below
        case .stdev:
            return "CASE WHEN COUNT(\(numeric))>1 THEN " +
                   "SQRT((SUM(\(numeric)*\(numeric)) - SUM(\(numeric))*SUM(\(numeric))/COUNT(\(numeric)))/(COUNT(\(numeric))-1)) ELSE 0 END"
        }
    }

    func aggregationTitle(_ agg: Aggregation) -> String {
        if let alias = agg.alias, !alias.isEmpty { return alias }
        if let idx = agg.columnIndex { return "\(agg.function.display)(\(columnName(idx)))" }
        return agg.function.display
    }

    func runAnalysis(_ spec: AnalysisSpec) throws -> ResultTable {
        if !spec.groupBy.isEmpty && spec.aggregations.contains(where: { $0.function == .median }) {
            throw AnalysisError.invalidPlan
        }
        let (w, p) = whereClause(spec.query)
        var selects: [String] = []
        var titles: [String] = []

        for g in spec.groupBy {
            guard let col = column(g) else { continue }
            selects.append(col)
            titles.append(columnName(g))
        }
        let aggs = spec.aggregations.isEmpty ? [Aggregation(function: .count, columnIndex: nil)] : spec.aggregations
        for a in aggs {
            selects.append(aggregateExpression(a))
            titles.append(aggregationTitle(a))
        }

        var sql = "SELECT " + selects.joined(separator: ", ") + " FROM main.\(sheet.tableName.sqlIdentifier)"
        if !w.isEmpty { sql += " WHERE \(w)" }
        if !spec.groupBy.isEmpty {
            sql += " GROUP BY " + spec.groupBy.compactMap { column($0) }.joined(separator: ", ")
        }
        if let s = spec.sortByResultColumn, s < selects.count {
            sql += " ORDER BY \(s + 1) \(spec.sortDescending ? "DESC" : "ASC")"
        } else if !spec.groupBy.isEmpty {
            sql += " ORDER BY \(spec.groupBy.count + 1) \(spec.sortDescending ? "DESC" : "ASC")"
        }
        let limit = max(1, min(spec.limit, 5000))
        sql += " LIMIT \(limit + 1)"

        var rows = try db.query(sql, p)
        var truncated = false
        if rows.count > limit { rows.removeLast(); truncated = true }
        if spec.groupBy.isEmpty, !rows.isEmpty {
            for (index, aggregation) in aggs.enumerated() where aggregation.function == .median {
                if let column = aggregation.columnIndex {
                    rows[0][index] = try median(columnIndex: column, query: spec.query).map { .double($0) } ?? .null
                }
            }
        }
        return ResultTable(columns: titles, rows: rows, truncated: truncated)
    }

    /// Exact median using an offset trick (works well even on millions of rows with an index-free scan).
    func median(columnIndex: Int, query: QuerySpec) throws -> Double? {
        guard let col = column(columnIndex) else { return nil }
        let (w, p) = whereClause(query)
        let numeric = "CAST(REPLACE(CAST(\(col) AS TEXT),',','') AS REAL)"
        var base = "FROM main.\(sheet.tableName.sqlIdentifier) WHERE \(numeric) IS NOT NULL AND typeof(\(col)) IN ('integer','real')"
        if !w.isEmpty { base += " AND \(w)" }
        let count = Int(try db.scalar("SELECT COUNT(*) \(base)", p).doubleValue ?? 0)
        guard count > 0 else { return nil }
        let sql = "SELECT AVG(x) FROM (SELECT \(numeric) AS x \(base) ORDER BY x LIMIT \(count % 2 == 0 ? 2 : 1) OFFSET \((count - 1) / 2))"
        return try db.scalar(sql, p).doubleValue
    }

    // MARK: Column profiling

    struct ColumnStats {
        var name: String
        var kind: ColumnKind
        var total: Int
        var nonEmpty: Int
        var distinct: Int
        var sum: Double?
        var avg: Double?
        var min: DBValue?
        var max: DBValue?
        var median: Double?
        var stdev: Double?
        var topValues: [(String, Int)] = []
    }

    func stats(for columnIndex: Int, query: QuerySpec = QuerySpec(), includeTop: Bool = true) throws -> ColumnStats {
        let info = sheet.columns[columnIndex]
        let col = "c\(columnIndex)"
        let (w, p) = whereClause(query)
        let whereSQL = w.isEmpty ? "" : " WHERE \(w)"
        let numeric = "CAST(REPLACE(CAST(\(col) AS TEXT),',','') AS REAL)"

        let base = try db.query("""
            SELECT COUNT(*),
                   SUM(CASE WHEN \(col) IS NOT NULL AND TRIM(CAST(\(col) AS TEXT))<>'' THEN 1 ELSE 0 END),
                   COUNT(DISTINCT \(col))
            FROM main.\(sheet.tableName.sqlIdentifier)\(whereSQL)
            """, p).first ?? []

        var s = ColumnStats(name: info.name, kind: info.kind,
                            total: Int(base.first?.doubleValue ?? 0),
                            nonEmpty: Int(base.count > 1 ? (base[1].doubleValue ?? 0) : 0),
                            distinct: Int(base.count > 2 ? (base[2].doubleValue ?? 0) : 0))

        if info.kind == .number {
            let row = try db.query("""
                SELECT SUM(\(numeric)), AVG(\(numeric)), MIN(\(numeric)), MAX(\(numeric)),
                       CASE WHEN COUNT(\(numeric))>1 THEN SQRT((SUM(\(numeric)*\(numeric)) - SUM(\(numeric))*SUM(\(numeric))/COUNT(\(numeric)))/(COUNT(\(numeric))-1)) ELSE 0 END
                FROM main.\(sheet.tableName.sqlIdentifier)\(whereSQL)
                """, p).first ?? []
            if row.count >= 5 {
                s.sum = row[0].doubleValue
                s.avg = row[1].doubleValue
                s.min = row[2]
                s.max = row[3]
                s.stdev = row[4].doubleValue
            }
            s.median = try median(columnIndex: columnIndex, query: query)
        } else {
            let row = try db.query("SELECT MIN(\(col)), MAX(\(col)) FROM main.\(sheet.tableName.sqlIdentifier)\(whereSQL)", p).first ?? []
            if row.count >= 2 { s.min = row[0]; s.max = row[1] }
        }

        if includeTop {
            let rows = try db.query("""
                SELECT CAST(\(col) AS TEXT) AS v, COUNT(*) AS n
                FROM main.\(sheet.tableName.sqlIdentifier)\(whereSQL)
                \(whereSQL.isEmpty ? "WHERE" : "AND") \(col) IS NOT NULL AND TRIM(CAST(\(col) AS TEXT))<>''
                GROUP BY v ORDER BY n DESC LIMIT 10
                """, p)
            s.topValues = rows.map { ($0[0].stringValue, Int($0[1].doubleValue ?? 0)) }
        }
        return s
    }

    func distinctValues(columnIndex: Int, limit: Int = 500) throws -> [String] {
        let col = "c\(columnIndex)"
        let rows = try db.query("""
            SELECT DISTINCT CAST(\(col) AS TEXT) FROM main.\(sheet.tableName.sqlIdentifier)
            WHERE \(col) IS NOT NULL AND TRIM(CAST(\(col) AS TEXT))<>''
            ORDER BY 1 LIMIT \(limit)
            """)
        return rows.map { $0[0].stringValue }
    }

    func duplicateGroups(columns: [Int], limit: Int = 200, query: QuerySpec = QuerySpec()) throws -> ResultTable {
        let cols = columns.compactMap { column($0) }
        guard !cols.isEmpty else { return ResultTable(columns: [], rows: []) }
        let sel = cols.joined(separator: ",")
        let (whereSQL, params) = whereClause(query)
        let cap = max(1, min(limit, 5000))
        var rows = try db.query("""
            SELECT \(sel), COUNT(*) AS n FROM main.\(sheet.tableName.sqlIdentifier)
            \(whereSQL.isEmpty ? "" : "WHERE " + whereSQL)
            GROUP BY \(sel) HAVING n > 1 ORDER BY n DESC LIMIT \(cap + 1)
            """, params)
        let truncated = rows.count > cap
        if truncated { rows.removeLast() }
        return ResultTable(columns: columns.map { columnName($0) } + ["Count"], rows: rows, truncated: truncated)
    }

    /// Free-form SQL against the sheet table, exposed as `data`.
    func runSQL(_ raw: String) throws -> ResultTable {
        let reader: Database
        if db.analysisPolicy != nil {
            reader = db
        } else {
            reader = try Database(path: db.path, analysisPolicy: AnalysisQueryPolicy(tableName: sheet.tableName))
        }
        return try reader.readResult(raw, limit: 500)
    }

    /// Creates an index on a column to speed up repeated filtering/sorting.
    func ensureIndex(columnIndex: Int) {
        guard let col = column(columnIndex) else { return }
        let name = "idx_\(sheet.tableName)_\(col)"
        try? db.exec("CREATE INDEX IF NOT EXISTS \(name.sqlIdentifier) ON \(sheet.tableName.sqlIdentifier)(\(col));")
    }

    // MARK: - Pivot tables

    struct PivotSpec {
        /// Row dimensions (1…2 column indexes), in order.
        var rowColumns: [Int] = []
        /// Optional cross-tab column dimension.
        var columnDim: Int?
        /// Metric column (nil = plain COUNT).
        var valueColumn: Int?
        var function: AggFunction = .count
        var query = QuerySpec()
        var rowLimit: Int = 100
        var columnLimit: Int = 25
    }

    struct PivotResult {
        var rowDimNames: [String] = []
        var columnDimName: String?
        var metricName: String = ""
        /// Raw (possibly empty) labels per row, one array per row dimension.
        var rowKeys: [[String]] = []
        var columnKeys: [String] = []
        /// cells[row][col]; nil = no data for that combination.
        var cells: [[Double?]] = []
        var rowTotals: [Double] = []
        var columnTotals: [Double] = []
        var grandTotal: Double = 0
        var truncatedRows = false
        var truncatedColumns = false
        var groupCapReached = false
    }

    /// Cross-tabulation over the whole (optionally filtered) sheet in a single GROUP BY pass.
    func runPivot(_ spec: PivotSpec) throws -> PivotResult {
        let rowDims = spec.rowColumns.compactMap { column($0) != nil ? $0 : nil }
        guard !rowDims.isEmpty else {
            throw DBError.prepare("pivot needs at least one row dimension")
        }
        let colDim = spec.columnDim.flatMap { column($0) }
        let function: AggFunction = {
            if spec.function != .count, let v = spec.valueColumn,
               v >= 0, v < sheet.columns.count, sheet.columns[v].kind != .number {
                return .count   // numeric metrics only make sense on numeric columns
            }
            return spec.function
        }()
        let metric = aggregateExpression(Aggregation(function: function, columnIndex: spec.valueColumn))
        let metricName = aggregationTitle(Aggregation(function: function, columnIndex: spec.valueColumn))

        var out = PivotResult()
        out.rowDimNames = rowDims.map { columnName($0) }
        out.columnDimName = colDim != nil ? columnName(spec.columnDim!) : nil
        out.metricName = metricName

        let (w, p) = whereClause(spec.query)
        let whereSQL = w.isEmpty ? "" : " WHERE \(w)"
        var selects: [String] = rowDims.map { column($0)! }
        if let cd = colDim { selects.append(cd) }
        let groupBy = selects.joined(separator: ",")
        let groupCap = 200_000
        let sql = "SELECT \(groupBy), \(metric) FROM main.\(sheet.tableName.sqlIdentifier)\(whereSQL) GROUP BY \(groupBy) LIMIT \(groupCap + 1)"
        var groups = try db.query(sql, p)
        if groups.count > groupCap {
            out.groupCapReached = true
            groups.removeLast()
        }

        let rowDimCount = rowDims.count
        let colIdx = rowDimCount + (colDim != nil ? 1 : 0)
        let valIdx = colIdx

        var rowTotals: [String: Double] = [:]
        var colTotals: [String: Double] = [:]
        var cells: [String: [String: Double]] = [:]
        for g in groups {
            let rowKey = g.prefix(rowDimCount).map { $0.stringValue }.joined(separator: "\u{1F}")
            let colKey = colDim != nil ? g[valIdx - 1].stringValue : ""
            let value = g[valIdx].doubleValue ?? 0
            rowTotals[rowKey, default: 0] += value
            colTotals[colKey, default: 0] += value
            cells[rowKey, default: [:]][colKey, default: 0] += value
        }

        // Order by total (desc), cap rows/columns, then materialise the matrix.
        let topRows = rowTotals.sorted { $0.value > $1.value }.prefix(spec.rowLimit)
        let topCols = colTotals.sorted { $0.value > $1.value }.prefix(spec.columnLimit)
        out.truncatedRows = topRows.count < rowTotals.count
        out.truncatedColumns = topCols.count < colTotals.count

        let rowSep = "\u{1F}"
        out.rowKeys = topRows.map { $0.key.components(separatedBy: rowSep) }
        out.rowTotals = topRows.map { $0.value }
        out.columnKeys = topCols.map { colDim != nil ? $0.key : metricName }
        out.columnTotals = topCols.map { $0.value }
        out.grandTotal = topRows.reduce(0) { $0 + $1.value }

        let colKeyLookup: [String] = topCols.map { $0.key }
        out.cells = topRows.map { rowEntry in
            let rowCells = cells[rowEntry.key] ?? [:]
            return colKeyLookup.map { rowCells[$0] }
        }
        return out
    }
}
