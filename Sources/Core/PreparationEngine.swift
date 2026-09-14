import Foundation

/// Two phases: materialize into a private DB attached to a read-only source;
/// then atomically copy the reviewed artifact into a new workbook/sheet.
enum PreparationEngine {
    static func readOnlyURI(_ path: String) -> String {
        var url = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return url.string!
    }

    static func validate(_ source: PreparationSource, db: Database, schema: String) throws {
        try source.validateStructure()
        let rows = try db.query("SELECT workbook_id,table_name,row_count FROM \(schema).meta_sheets WHERE id=? AND id NOT IN (SELECT sheet_id FROM \(schema).meta_sheet_trash)", [.int(source.id)])
        guard let row = rows.first, row[0] == .int(source.workbookID), row[1] == .text(source.tableName),
              row[2] == .int(Int64(source.rowCount)) else { throw PreparationError.sourceChanged }
        let columns = try db.query("SELECT col_index,name,kind FROM \(schema).meta_columns WHERE sheet_id=? ORDER BY col_index", [.int(source.id)])
        let expected = source.columns.map { [DBValue.int(Int64($0.index)), .text($0.name), .text($0.kind.rawValue)] }
        guard columns == expected else { throw PreparationError.sourceChanged }
        guard try count(db, "SELECT COUNT(*) FROM \(schema).\(source.tableName.sqlIdentifier)") == source.rowCount else {
            throw PreparationError.sourceChanged
        }
    }

    static func prepare(_ recipe: PreparationRecipe, workspacePath: String,
                        cancellation: QueryCancellation = QueryCancellation()) throws -> PreparationPreview {
        try recipe.validate()
        guard recipe.sources.allSatisfy({ $0.rowCount <= PreparationLimits.rows }) else { throw PreparationError.sourceLimit }
        let budget = PreparationBudget(cancellation: cancellation)
        try budget.check()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SheetX-preparation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let db = try Database(path: directory.appendingPathComponent("prepared.sqlite").path)
        try db.configurePreparation(budget: budget)
        try db.exec("PRAGMA journal_mode=DELETE;")
        let pageSize = try count(db, "PRAGMA page_size")
        try db.exec("PRAGMA max_page_count=\(PreparationLimits.stagingBytes / Int64(pageSize));")
        try db.run("ATTACH DATABASE ? AS source", [.text(readOnlyURI(workspacePath))])
        let preview = try db.withPreparationBudget(budget) {
            try db.exec("BEGIN;")
            do {
                for source in recipe.sources { try validate(source, db: db, schema: "source") }
                let preview: PreparationPreview
                switch recipe.operation {
                case .clean(let clean): preview = try cleanPreview(clean, recipe: recipe, db: db, directory: directory, budget: budget)
                case .join(let join): preview = try joinPreview(join, recipe: recipe, db: db, directory: directory)
                }
                try budget.check()
                try db.exec("COMMIT;")
                return preview
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
        retained = preview.artifact != nil
        return preview
    }

    static func count(_ db: Database, _ sql: String, _ parameters: [DBValue] = []) throws -> Int {
        guard case .int(let value) = try db.scalar(sql, parameters) else { return 0 }
        return Int(value)
    }

    private static func sample(_ db: Database, table: String, columns: [ColumnInfo], originalRow: Bool = false) throws -> ResultTable {
        let names = columns.map { $0.sqlName.sqlIdentifier + " AS " + $0.name.sqlIdentifier }.joined(separator: ",")
        let prefix = originalRow ? "rowid AS \("prep.sourceRow".loc.sqlIdentifier)," : ""
        return try db.readResult("SELECT \(prefix)\(names) FROM \(table) ORDER BY rowid", limit: PreparationLimits.previewRows, maxBytes: 4 * 1024 * 1024)
    }

    private static func columnInfo(_ source: PreparationSource) -> [ColumnInfo] {
        source.columns.map { ColumnInfo(index: $0.index, name: $0.name, kind: $0.kind) }
    }

    private static func cleanPreview(_ clean: CleaningRecipe, recipe: PreparationRecipe, db: Database,
                                     directory: URL, budget: PreparationBudget) throws -> PreparationPreview {
        var columns = columnInfo(clean.source)
        let before = try sample(db, table: "source.\(clean.source.tableName.sqlIdentifier)", columns: columns, originalRow: true)
        let fields = columns.map { $0.sqlName.sqlIdentifier }.joined(separator: ",")
        // No declared affinity: preserve leading-zero identifiers and original SQLite storage types.
        try db.exec("CREATE TABLE output(\(fields));")
        try db.exec("INSERT INTO output(rowid,\(fields)) SELECT rowid,\(fields) FROM source.\(clean.source.tableName.sqlIdentifier) ORDER BY rowid;")
        try db.exec("CREATE TABLE rejected(step INTEGER,source_row INTEGER,column_name TEXT,original_value);")
        var impacts: [CleaningImpact] = []
        for (index, step) in clean.steps.enumerated() {
            try budget.check()
            let column = "c\(step.column)".sqlIdentifier
            var changed = 0, removed = 0, invalid = 0
            if step.operation == .removeDuplicates {
                removed = try db.run("DELETE FROM output WHERE rowid NOT IN (SELECT MIN(rowid) FROM output GROUP BY \(fields))")
            } else if step.operation == .dropMissing {
                removed = try db.run("DELETE FROM output WHERE sx_clean(\(column),'blank','','')=1")
            } else {
                let first = step.operation == .parseNumber ? step.numberConvention.rawValue
                    : (step.operation == .parseDate ? step.dateFormat.rawValue : step.value)
                try db.exec("CREATE TABLE transformed(rid INTEGER PRIMARY KEY,v);")
                try db.run("INSERT INTO transformed SELECT rowid,sx_clean(\(column),?,?,?) FROM output",
                           [.text(step.operation.rawValue), .text(first), .text(step.replacement)])
                let conversion = step.operation == .parseNumber || step.operation == .parseDate
                if conversion {
                    let invalidWhere = "t.v IS NULL AND sx_clean(o.\(column),'blank','','')=0"
                    invalid = try count(db, "SELECT COUNT(*) FROM output o JOIN transformed t ON o.rowid=t.rid WHERE \(invalidWhere)")
                    try db.run("INSERT INTO rejected SELECT ?,o.rowid,?,o.\(column) FROM output o JOIN transformed t ON o.rowid=t.rid WHERE \(invalidWhere) ORDER BY o.rowid LIMIT 10",
                               [.int(Int64(index + 1)), .text(columns[step.column].name)])
                    // Invalid conversions explicitly retain the original, never silently erase data.
                    try db.exec("UPDATE transformed SET v=(SELECT \(column) FROM output WHERE rowid=rid) WHERE v IS NULL AND sx_clean((SELECT \(column) FROM output WHERE rowid=rid),'blank','','')=0;")
                }
                changed = try count(db, "SELECT COUNT(*) FROM output o JOIN transformed t ON o.rowid=t.rid WHERE o.\(column) IS NOT t.v OR typeof(o.\(column))!=typeof(t.v)")
                try db.exec("UPDATE output SET \(column)=(SELECT v FROM transformed WHERE rid=output.rowid); DROP TABLE transformed;")
                // A mixed column must not be advertised as fully converted.
                if conversion { columns[step.column].kind = invalid == 0 ? (step.operation == .parseNumber ? .number : .date) : .text }
                if step.operation == .fillMissing || (step.operation == .replaceText && changed > 0) { columns[step.column].kind = .text }
            }
            impacts.append(CleaningImpact(id: step.id, operation: step.operation,
                                          columnName: step.operation.needsColumn ? columns[step.column].name : "",
                                          changed: changed, removed: removed, invalid: invalid))
        }
        let rows = try count(db, "SELECT COUNT(*) FROM output")
        let after = try sample(db, table: "output", columns: columns, originalRow: true)
        let rejected = try db.readResult("SELECT step,source_row,column_name,original_value FROM rejected ORDER BY step,source_row", limit: 30, maxBytes: 4 * 1024 * 1024)
        return PreparationPreview(recipe: recipe, summary: PreparationSummary(cleaning: impacts, outputRows: rows),
            before: before, after: after, rejected: rejected.rows.isEmpty ? nil : rejected,
            artifact: PreparedArtifact(directory: directory, columns: columns, rows: rows), blockReason: nil)
    }

    private static func joinPreview(_ join: JoinRecipe, recipe: PreparationRecipe, db: Database, directory: URL) throws -> PreparationPreview {
        for (label, source, key) in [("l", join.left, join.leftKey), ("r", join.right, join.rightKey)] {
            let column = "c\(key)".sqlIdentifier
            let value = join.keyMode == .exact ? column : "sx_clean(CAST(\(column) AS TEXT),'key','','')"
            try db.exec("CREATE TABLE \(label)k(rid INTEGER PRIMARY KEY,k);")
            try db.exec("INSERT INTO \(label)k SELECT rowid,CASE WHEN sx_clean(\(column),'blank','','')=1 THEN NULL ELSE \(value) END FROM source.\(source.tableName.sqlIdentifier);")
            try db.exec("CREATE INDEX \(label)ki ON \(label)k(k);")
            try db.exec("CREATE TABLE \(label)g(k,n INTEGER); INSERT INTO \(label)g SELECT k,COUNT(*) FROM \(label)k WHERE k IS NOT NULL GROUP BY k; CREATE UNIQUE INDEX \(label)gi ON \(label)g(k);")
        }
        let matched = try count(db, "SELECT COALESCE(SUM(l.n),0) FROM lg l JOIN rg r ON l.k=r.k")
        let matchedRight = try count(db, "SELECT COALESCE(SUM(r.n),0) FROM rg r JOIN lg l ON r.k=l.k")
        let pairs = try count(db, "SELECT COALESCE(SUM(l.n*r.n),0) FROM lg l JOIN rg r ON l.k=r.k")
        let rows = pairs + (join.mode == .inner ? 0 : join.left.rowCount - matched)
        let diagnostics = JoinDiagnostics(leftRows: join.left.rowCount, rightRows: join.right.rowCount,
            matchedLeft: matched, unmatchedLeft: join.left.rowCount - matched, unmatchedRight: join.right.rowCount - matchedRight,
            blankLeftKeys: try count(db, "SELECT COUNT(*) FROM lk WHERE k IS NULL"),
            blankRightKeys: try count(db, "SELECT COUNT(*) FROM rk WHERE k IS NULL"),
            duplicateLeftKeys: try count(db, "SELECT COUNT(*) FROM lg WHERE n>1"),
            duplicateRightKeys: try count(db, "SELECT COUNT(*) FROM rg WHERE n>1"), outputRows: rows)
        var columns = columnInfo(join.left)
        var used = Set(columns.map { $0.name.lowercased() })
        for index in join.rightColumns {
            let source = join.right.columns[index]
            let base = "\(join.right.name).\(source.name)"
            var name = base, suffix = 2
            while used.contains(name.lowercased()) { name = "\(base) (\(suffix))"; suffix += 1 }
            used.insert(name.lowercased())
            columns.append(ColumnInfo(index: columns.count, name: name, kind: source.kind))
        }
        let blocked: PreparationError? = join.mode == .lookup && diagnostics.duplicateRightKeys > 0
            ? .lookupDuplicates : (rows > PreparationLimits.rows ? .outputLimit : nil)
        if let blocked {
            return PreparationPreview(recipe: recipe, summary: PreparationSummary(join: diagnostics, outputRows: rows),
                before: nil, after: ResultTable(columns: columns.map(\.name), rows: []), rejected: nil, artifact: nil,
                blockReason: blocked.localizedDescription)
        }
        let fields = columns.map { $0.sqlName.sqlIdentifier }.joined(separator: ",")
        let select = (join.left.columns.map { "l.\("c\($0.index)".sqlIdentifier)" }
            + join.rightColumns.map { "r.\("c\($0)".sqlIdentifier)" }).joined(separator: ",")
        let mode = join.mode == .inner ? "JOIN" : "LEFT JOIN"
        try db.exec("CREATE TABLE output(\(fields));")
        try db.exec("""
            INSERT INTO output SELECT \(select) FROM lk
            JOIN source.\(join.left.tableName.sqlIdentifier) l ON l.rowid=lk.rid
            \(mode) rk ON lk.k=rk.k
            \(mode) source.\(join.right.tableName.sqlIdentifier) r ON r.rowid=rk.rid
            ORDER BY lk.rid,rk.rid;
            """)
        let actual = try count(db, "SELECT COUNT(*) FROM output")
        guard actual == rows else { throw PreparationError.sourceChanged }
        return PreparationPreview(recipe: recipe, summary: PreparationSummary(join: diagnostics, outputRows: rows),
            before: nil, after: try sample(db, table: "output", columns: columns), rejected: nil,
            artifact: PreparedArtifact(directory: directory, columns: columns, rows: rows), blockReason: nil)
    }

    static func publish(_ preview: PreparationPreview, name: String, workspacePath: String,
                        approveDuplicates: Bool, approveInvalid: Bool,
                        cancellation: QueryCancellation = QueryCancellation()) throws -> WorkbookInfo {
        try preview.recipe.validate()
        guard let artifact = preview.artifact, preview.blockReason == nil, artifact.rows <= PreparationLimits.rows else { throw PreparationError.outputLimit }
        if preview.needsDuplicateApproval && !approveDuplicates { throw PreparationError.approveDuplicates }
        if preview.needsInvalidApproval && !approveInvalid { throw PreparationError.approveInvalid }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw PreparationError.recipe }
        let budget = PreparationBudget(cancellation: cancellation)
        try budget.check()
        let recipeData = try JSONEncoder().encode(preview.recipe), summaryData = try JSONEncoder().encode(preview.summary)
        guard recipeData.count <= 512 * 1024 else { throw PreparationError.recipe }
        let db = try Database(path: workspacePath)
        try db.configurePreparation(budget: budget)
        try db.run("ATTACH DATABASE ? AS prepared", [.text(readOnlyURI(artifact.databaseURL.path))])
        // Migration runs before the transaction on this independent connection.
        let workspace = try Workspace(db: db)
        return try db.withPreparationBudget(budget) {
            try db.transaction {
                for source in preview.recipe.sources { try validate(source, db: db, schema: "main") }
                guard try count(db, "SELECT COUNT(*) FROM prepared.output") == artifact.rows else { throw PreparationError.sourceChanged }
                let workbookID = try workspace.createWorkbook(name: title, fileName: "Derived sheet", size: 0)
                let sheetID = try workspace.createSheet(workbookID: workbookID, name: title, index: 0)
                let fields = artifact.columns.map { $0.sqlName.sqlIdentifier }.joined(separator: ",")
                try db.exec("CREATE TABLE \("data_\(sheetID)".sqlIdentifier)(\(fields));")
                // Fresh compact rowids keep the grid's paging/go-to semantics intact.
                try db.exec("INSERT INTO \("data_\(sheetID)".sqlIdentifier) SELECT \(fields) FROM prepared.output ORDER BY rowid;")
                try workspace.saveColumns(sheetID: sheetID, columns: artifact.columns)
                try workspace.setRowCount(sheetID: sheetID, count: artifact.rows)
                try db.run("INSERT INTO meta_preparations(sheet_id,recipe,summary,created_at) VALUES(?,?,?,?)",
                    [.int(sheetID), .text(String(decoding: recipeData, as: UTF8.self)), .text(String(decoding: summaryData, as: UTF8.self)), .double(Date().timeIntervalSince1970)])
                try budget.check()
                return WorkbookInfo(id: workbookID, name: title, originalFileName: "Derived sheet", sizeBytes: 0,
                    importedAt: Date(), sheets: [SheetInfo(id: sheetID, workbookID: workbookID, name: title,
                        tableName: "data_\(sheetID)", rowCount: artifact.rows, columns: artifact.columns, index: 0, isDerived: true)])
            }
        }
    }
}

struct PreparationRecord {
    let recipe: PreparationRecipe?
    let summary: PreparationSummary?
    let createdAt: Date
}

extension Workspace {
    func preparation(sheetID: Int64) throws -> PreparationRecord? {
        guard let row = try db.query("SELECT recipe,summary,created_at FROM meta_preparations WHERE sheet_id=?", [.int(sheetID)]).first else { return nil }
        let recipe = row[0].stringValue, summary = row[1].stringValue
        return PreparationRecord(recipe: recipe.utf8.count <= 512 * 1024 ? try? JSONDecoder().decode(PreparationRecipe.self, from: Data(recipe.utf8)) : nil,
            summary: summary.utf8.count <= 512 * 1024 ? try? JSONDecoder().decode(PreparationSummary.self, from: Data(summary.utf8)) : nil,
            createdAt: Date(timeIntervalSince1970: row[2].doubleValue ?? 0))
    }
}
