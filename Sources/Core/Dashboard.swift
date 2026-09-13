import Foundation

enum DashboardDisplay: String, Codable, CaseIterable, Identifiable {
    case kpi, bar, line, table
    var id: String { rawValue }
    var title: String { "dash.display.\(rawValue)".loc }
}

enum DashboardMetric: String, Codable, CaseIterable, Identifiable {
    case count, sum, average, minimum, maximum, distinct
    var id: String { rawValue }
    var title: String { "dash.metric.\(rawValue)".loc }
    var needsColumn: Bool { self != .count }
}

struct DashboardCard: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var display: DashboardDisplay = .kpi
    var metric: DashboardMetric = .count
    var valueColumn = 0
    var groupColumn = 0
}

struct DashboardSelection: Codable, Hashable {
    var column: Int
    var value: DBValue
}

struct DashboardRecipe: Codable, Hashable {
    var version = 1
    var source: PreparationSource
    var title: String
    var cards: [DashboardCard]
    var query = QuerySpec()
    var selection: DashboardSelection?

    static func starter(sheet: SheetInfo, query: QuerySpec = QuerySpec()) -> DashboardRecipe {
        var cards = [DashboardCard(title: "dash.rows".loc)]
        if let number = sheet.columns.first(where: { $0.kind == .number }) {
            cards.append(DashboardCard(title: "dash.metric.sum".loc + " · " + number.name, metric: .sum, valueColumn: number.index))
        }
        if let column = sheet.columns.first(where: { $0.kind == .text }) ?? sheet.columns.first {
            cards.append(DashboardCard(title: "dash.by".loc + " " + column.name, display: .bar, groupColumn: column.index))
        }
        cards.append(DashboardCard(title: "dash.display.table".loc, display: .table))
        var query = query; query.sorts = []; query.distinctColumns = []
        return DashboardRecipe(source: PreparationSource(sheet), title: String(sheet.name.prefix(100)), cards: cards, query: query)
    }

    func validate(for sheet: SheetInfo) throws {
        let current = PreparationSource(sheet)
        guard version == 1, source.id == current.id, source.workbookID == current.workbookID,
              source.tableName == "data_\(sheet.id)", source.columns == current.columns, source.rowCount == current.rowCount,
              !sheet.columns.isEmpty, sheet.columns.count <= 128,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120,
              !cards.isEmpty, cards.count <= 12, Set(cards.map(\.id)).count == cards.count,
              query.filters.count <= 16, query.search.count <= 1000, query.sorts.isEmpty, query.distinctColumns.isEmpty else {
            throw DashboardError.invalid
        }
        var plan = CommandPlan(); plan.analysis.query = query
        try plan.validate(for: sheet)
        for filter in query.filters {
            guard filter.op != .regex, filter.value.count <= 1000, filter.value2.count <= 1000 else { throw DashboardError.invalid }
        }
        if let selection {
            guard sheet.columns.indices.contains(selection.column), selection.value.stringValue.utf8.count <= 4096 else { throw DashboardError.invalid }
            if case .double(let value) = selection.value, !value.isFinite { throw DashboardError.invalid }
        }
        for card in cards {
            guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, card.title.count <= 120 else { throw DashboardError.invalid }
            if card.display != .table && card.metric.needsColumn {
                guard sheet.columns.indices.contains(card.valueColumn) else { throw DashboardError.invalid }
            }
            if card.display == .bar || card.display == .line {
                guard sheet.columns.indices.contains(card.groupColumn) else { throw DashboardError.invalid }
            }
        }
    }
}

enum DashboardError: LocalizedError {
    case invalid
    var errorDescription: String? { "dash.invalid".loc }
}

struct DashboardCardResult: Identifiable {
    let id: UUID
    let table: ResultTable
}

struct DashboardSnapshot {
    let cards: [DashboardCardResult]
    let matchingRows: Int
    let completedAt: Date
}

/// One read-only snapshot and a shared 15-second cancellation budget for all cards.
/// Only bound, generated SQL; the existing analysis authorizer remains unchanged.
enum DashboardRunner {
    static func run(_ recipe: DashboardRecipe, sheet: SheetInfo, path: String,
                    cancellation: QueryCancellation = QueryCancellation()) throws -> DashboardSnapshot {
        try recipe.validate(for: sheet)
        let policy = AnalysisQueryPolicy(tableName: sheet.tableName, cancellation: cancellation)
        let db = try Database(path: path, analysisPolicy: policy)
        let engine = QueryEngine(db: db, sheet: sheet)
        let (base, parameters) = engine.whereClause(recipe.query)
        var terms = base.isEmpty ? [] : ["(\(base))"], params = parameters
        if let selection = recipe.selection {
            let column = "c\(selection.column)".sqlIdentifier
            switch selection.value {
            case .null: terms.append("\(column) IS NULL")
            case .text:
                terms.append("(typeof(\(column))='text' AND \(column)=? COLLATE BINARY)"); params.append(selection.value)
            default:
                terms.append("(typeof(\(column)) IN ('integer','real') AND \(column)=?)"); params.append(selection.value)
            }
        }
        let whereSQL = terms.isEmpty ? "" : " WHERE " + terms.joined(separator: " AND ")
        let source = "main.\(sheet.tableName.sqlIdentifier)"
        let rows = try PreparationEngine.count(db, "SELECT COUNT(*) FROM \(source)\(whereSQL)", params)
        var output: [DashboardCardResult] = [], bytes = 0
        for card in recipe.cards {
            try policy.check()
            let sql: String
            let limit: Int
            if card.display == .table {
                limit = 50
                let fields = sheet.columns.map { $0.sqlName.sqlIdentifier + " AS " + $0.name.sqlIdentifier }.joined(separator: ",")
                sql = "SELECT \(fields) FROM \(source)\(whereSQL) ORDER BY rowid LIMIT 51"
            } else {
                let column = "c\(card.valueColumn)".sqlIdentifier
                // Invalid numeric text never becomes zero. Explicit cleaning can convert text first.
                let numeric = "CASE WHEN typeof(\(column)) IN ('integer','real') THEN \(column) END"
                let expression: String
                switch card.metric {
                case .count: expression = "COUNT(*)"
                case .sum: expression = "SUM(\(numeric))"
                case .average: expression = "AVG(\(numeric))"
                case .minimum: expression = "MIN(\(numeric))"
                case .maximum: expression = "MAX(\(numeric))"
                case .distinct: expression = "COUNT(DISTINCT \(column))"
                }
                if card.display == .kpi {
                    limit = 1
                    sql = "SELECT \(expression) AS \(card.metric.title.sqlIdentifier) FROM \(source)\(whereSQL)"
                } else {
                    limit = card.display == .bar ? 12 : 24
                    let group = "c\(card.groupColumn)".sqlIdentifier
                    let order = card.display == .bar ? "2 DESC,1 ASC" : "1 ASC"
                    sql = "SELECT \(group) AS \(sheet.columns[card.groupColumn].name.sqlIdentifier),\(expression) AS \(card.metric.title.sqlIdentifier) FROM \(source)\(whereSQL) GROUP BY \(group) ORDER BY \(order) LIMIT \(limit + 1)"
                }
            }
            let table = try db.readResult(sql, params, limit: limit)
            bytes += table.rows.reduce(0) { sum, row in sum + row.reduce(0) { $0 + $1.stringValue.utf8.count + 32 } }
            guard bytes <= 4 * 1024 * 1024 else { throw AnalysisError.resultTooLarge }
            output.append(DashboardCardResult(id: card.id, table: table))
        }
        try policy.check()
        return DashboardSnapshot(cards: output, matchingRows: rows, completedAt: Date())
    }
}

struct StoredDashboard: Identifiable {
    let id: Int64 // source sheet ID; one saved dashboard per source
    let title: String
    let recipe: DashboardRecipe?
}

extension Workspace {
    func saveDashboard(_ recipe: DashboardRecipe, sheet: SheetInfo) throws {
        try recipe.validate(for: sheet)
        let data = try JSONEncoder().encode(recipe)
        guard data.count <= 128 * 1024 else { throw DashboardError.invalid }
        try db.transaction {
            try PreparationEngine.validate(recipe.source, db: db, schema: "main")
            try db.run("INSERT INTO meta_dashboards(sheet_id,title,payload) VALUES(?,?,?) ON CONFLICT(sheet_id) DO UPDATE SET title=excluded.title,payload=excluded.payload",
                       [.int(sheet.id), .text(recipe.title), .text(String(decoding: data, as: UTF8.self))])
        }
    }

    func loadDashboards() throws -> [StoredDashboard] {
        try db.query("SELECT sheet_id,title,payload FROM meta_dashboards ORDER BY sheet_id DESC LIMIT 200").map { row in
            let payload = row[2].stringValue
            return StoredDashboard(id: Int64(row[0].doubleValue ?? 0), title: row[1].stringValue,
                recipe: payload.utf8.count <= 128 * 1024 ? try? JSONDecoder().decode(DashboardRecipe.self, from: Data(payload.utf8)) : nil)
        }
    }

    func dashboard(sheetID: Int64) throws -> DashboardRecipe? {
        guard let row = try db.query("SELECT payload FROM meta_dashboards WHERE sheet_id=?", [.int(sheetID)]).first else { return nil }
        let payload = row[0].stringValue
        guard payload.utf8.count <= 128 * 1024, let recipe = try? JSONDecoder().decode(DashboardRecipe.self, from: Data(payload.utf8)) else { throw DashboardError.invalid }
        return recipe
    }

    func deleteDashboard(sheetID: Int64) throws {
        try db.run("DELETE FROM meta_dashboards WHERE sheet_id=?", [.int(sheetID)])
    }
}
