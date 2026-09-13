import Foundation

struct AnalysisOutput {
    let table: ResultTable?
    let report: String?
    let elapsed: TimeInterval
    let completedAt: Date
}

enum AnalysisRunner {
    /// The detached worker owns and closes its connection. The parent task's
    /// cancellation is explicitly bridged into SQLite's progress callback.
    static func read<T>(path: String, sheet: SheetInfo, timeout: TimeInterval = 15,
                        work: @escaping (QueryEngine) throws -> T) async throws -> T {
        let cancellation = QueryCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                let policy = AnalysisQueryPolicy(tableName: sheet.tableName,
                                                 cancellation: cancellation, timeout: timeout)
                try policy.check()
                let db = try Database(path: path, analysisPolicy: policy)
                let value = try work(QueryEngine(db: db, sheet: sheet))
                try policy.check()
                return value
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    static func execute(plan: CommandPlan, path: String, sheet: SheetInfo, arabic: Bool) async throws -> AnalysisOutput {
        try plan.validate(for: sheet)
        let start = ProcessInfo.processInfo.systemUptime
        return try await read(path: path, sheet: sheet) { engine in
            var table: ResultTable?
            var report: String?
            switch plan.kind {
            case .summary:
                report = try ReportBuilder(engine: engine, arabic: arabic).fullReport(query: plan.analysis.query)
            case .duplicates:
                table = try engine.duplicateGroups(columns: plan.analysis.groupBy.isEmpty
                                                    ? [sheet.columns.first?.index ?? 0] : plan.analysis.groupBy,
                                                    limit: plan.analysis.limit, query: plan.analysis.query)
            case .aggregate, .chart:
                table = try engine.runAnalysis(plan.analysis)
            case .sql:
                table = try engine.runSQL(plan.sql)
            case .filterRows, .topN:
                let cap = max(1, min(plan.analysis.limit, 500))
                var rows = try engine.fetchRows(plan.analysis.query, offset: 0, limit: cap + 1)
                let truncated = rows.count > cap
                if truncated { rows.removeLast() }
                table = ResultTable(columns: sheet.columns.map(\.name),
                                    rows: rows.map { Array($0.dropFirst()) }, truncated: truncated)
            }
            return AnalysisOutput(table: table, report: report,
                                  elapsed: ProcessInfo.processInfo.systemUptime - start, completedAt: Date())
        }
    }
}
