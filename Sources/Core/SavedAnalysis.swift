import Foundation

struct AnalysisColumnSignature: Codable, Hashable {
    let index: Int
    let name: String
    let kind: ColumnKind
}

/// Store the executable plan, not a chat prompt that could produce a different
/// answer next time. Imported sheets have immutable data and unique IDs.
struct SavedAnalysisRecipe: Codable {
    let version: Int
    let sheetID: Int64
    let tableName: String
    let sourceRowCount: Int
    let columns: [AnalysisColumnSignature]
    let command: String
    let plan: CommandPlan

    init(sheet: SheetInfo, command: String, plan: CommandPlan) {
        version = 1
        sheetID = sheet.id
        tableName = sheet.tableName
        sourceRowCount = sheet.rowCount
        columns = sheet.columns.map { AnalysisColumnSignature(index: $0.index, name: $0.name, kind: $0.kind) }
        self.command = command
        self.plan = plan
    }

    func validate(for sheet: SheetInfo) throws {
        let current = sheet.columns.map { AnalysisColumnSignature(index: $0.index, name: $0.name, kind: $0.kind) }
        guard version == 1, sheetID == sheet.id, tableName == sheet.tableName,
              sourceRowCount == sheet.rowCount, columns == current else {
            throw AnalysisError.incompatibleRecipe
        }
        try plan.validate(for: sheet)
    }
}

struct SavedAnalysis: Identifiable {
    let id: Int64
    let title: String
    let createdAt: Date
    // A corrupt/unknown payload is still listed so it can be removed, never silently lost.
    let recipe: SavedAnalysisRecipe?
}

extension CommandPlan {
    func validate(for sheet: SheetInfo) throws {
        let valid = Set(sheet.columns.map(\.index))
        let query = analysis.query
        let referenced = analysis.groupBy + query.filters.map(\.columnIndex)
            + query.sorts.map(\.columnIndex) + query.searchColumns + query.distinctColumns
            + analysis.aggregations.compactMap(\.columnIndex) + [chartColumn].compactMap { $0 }
        guard referenced.allSatisfy({ valid.contains($0) }), analysis.limit > 0,
              query.distinctColumns.isEmpty else { throw AnalysisError.invalidPlan }
        if kind == .sql {
            guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sql.utf8.count <= 100_000 else { throw AnalysisError.invalidPlan }
        }
        if let sort = analysis.sortByResultColumn {
            let outputCount = analysis.groupBy.count + max(1, analysis.aggregations.count)
            guard sort >= 0, sort < outputCount else { throw AnalysisError.invalidPlan }
        }
        for aggregation in analysis.aggregations {
            if aggregation.function.needsColumn && aggregation.columnIndex == nil {
                throw AnalysisError.invalidPlan
            }
        }
        for filter in query.filters where filter.op == .inList {
            guard !filter.value.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "،" })
                .allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw AnalysisError.invalidPlan
            }
        }
    }
}

extension Workspace {
    func saveAnalysis(title: String, recipe: SavedAnalysisRecipe, sheet: SheetInfo) throws {
        try recipe.validate(for: sheet)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw AnalysisError.invalidPlan }
        let payload = try JSONEncoder().encode(recipe)
        guard payload.count <= 250_000 else { throw AnalysisError.resultTooLarge }
        // INSERT...SELECT refuses to create orphan records if a source was deleted.
        let changed = try db.run("""
            INSERT INTO meta_saved_queries(sheet_id,title,payload,created_at)
            SELECT id,?,?,? FROM meta_sheets WHERE id=? AND id NOT IN (SELECT sheet_id FROM meta_sheet_trash)
            """, [.text(name), .text(String(decoding: payload, as: UTF8.self)),
                  .double(Date().timeIntervalSince1970), .int(sheet.id)])
        guard changed == 1 else { throw AnalysisError.incompatibleRecipe }
    }

    func loadAnalyses(sheetID: Int64) throws -> [SavedAnalysis] {
        try db.query("""
            SELECT id,title,payload,created_at FROM meta_saved_queries
            WHERE sheet_id=? AND sheet_id NOT IN (SELECT sheet_id FROM meta_sheet_trash) ORDER BY created_at DESC,id DESC LIMIT 200
            """, [.int(sheetID)]).map { row in
                SavedAnalysis(id: Int64(row[0].doubleValue ?? 0), title: row[1].stringValue,
                              createdAt: Date(timeIntervalSince1970: row[3].doubleValue ?? 0),
                              recipe: try? JSONDecoder().decode(SavedAnalysisRecipe.self,
                                                               from: Data(row[2].stringValue.utf8)))
            }
    }

    func renameAnalysis(id: Int64, sheetID: Int64, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw AnalysisError.invalidPlan }
        try db.run("UPDATE meta_saved_queries SET title=? WHERE id=? AND sheet_id=? AND sheet_id NOT IN (SELECT sheet_id FROM meta_sheet_trash)",
                   [.text(name), .int(id), .int(sheetID)])
    }

    func deleteAnalysis(id: Int64, sheetID: Int64) throws {
        try db.run("DELETE FROM meta_saved_queries WHERE id=? AND sheet_id=? AND sheet_id NOT IN (SELECT sheet_id FROM meta_sheet_trash)", [.int(id), .int(sheetID)])
    }
}
