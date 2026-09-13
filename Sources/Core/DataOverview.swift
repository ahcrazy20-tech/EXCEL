import Foundation

struct OverviewColumn: Identifiable {
    var id: Int { column.index }
    let column: ColumnInfo
    let sampledRows: Int
    let missing: Int
    let distinct: Int
    let numericValues: Int
    let average: Double?
    let minimum: Double?
    let maximum: Double?

    var invalidNumbers: Int { column.kind == .number ? max(0, sampledRows - missing - numericValues) : 0 }
}

struct DataOverview {
    let matchingRows: Int
    let sampledRows: Int
    let columns: [OverviewColumn]
    let completedAt: Date
    var isSampled: Bool { sampledRows < matchingRows }
    var missingCells: Int { columns.reduce(0) { $0 + $1.missing } }
    var completeness: Double? {
        let cells = sampledRows * columns.count
        return cells > 0 ? 1 - Double(missingCells) / Double(cells) : nil
    }

    /// Exact matching row count + clearly labelled, deterministic first-N profiling.
    /// No sample rows are materialized or sent to AI. Each SQL result is just one row.
    static func build(engine: QueryEngine, query: QuerySpec, sampleLimit: Int = 10_000,
                      progress: (Int, Int) -> Void = { _, _ in }) throws -> DataOverview {
        var validation = CommandPlan()
        validation.analysis.query = query
        try validation.validate(for: engine.sheet)
        let total = try engine.countRows(query)
        let cap = max(1, min(sampleLimit, 10_000))
        let (whereSQL, params) = engine.whereClause(query)
        var columns: [OverviewColumn] = []
        for (position, column) in engine.sheet.columns.enumerated() {
            try engine.db.analysisPolicy?.check()
            let blank = "value IS NULL OR TRIM(CAST(value AS TEXT))=''"
            let numeric = "CASE WHEN typeof(value) IN ('integer','real') THEN value END"
            let rows = try engine.db.query("""
                WITH sample AS (
                    SELECT \(column.sqlName.sqlIdentifier) AS value FROM \(engine.sheet.tableName.sqlIdentifier)
                    \(whereSQL.isEmpty ? "" : "WHERE " + whereSQL) ORDER BY rowid LIMIT \(cap)
                )
                SELECT COUNT(*), COALESCE(SUM(CASE WHEN \(blank) THEN 1 ELSE 0 END),0),
                       COUNT(DISTINCT CASE WHEN NOT (\(blank)) THEN value END),
                       COUNT(\(numeric)), AVG(\(numeric)), MIN(\(numeric)), MAX(\(numeric))
                FROM sample
                """, params)
            guard let row = rows.first, row.count == 7 else { throw AnalysisError.invalidPlan }
            columns.append(OverviewColumn(column: column,
                                          sampledRows: Int(row[0].doubleValue ?? 0),
                                          missing: Int(row[1].doubleValue ?? 0),
                                          distinct: Int(row[2].doubleValue ?? 0),
                                          numericValues: Int(row[3].doubleValue ?? 0),
                                          average: row[4].doubleValue, minimum: row[5].doubleValue,
                                          maximum: row[6].doubleValue))
            progress(position + 1, engine.sheet.columns.count)
        }
        return DataOverview(matchingRows: total, sampledRows: min(total, cap), columns: columns, completedAt: Date())
    }
}
