import Foundation

enum ColumnKind: String, Codable {
    case number, text, date, boolean

    var symbol: String {
        switch self {
        case .number: return "number"
        case .text: return "textformat.abc"
        case .date: return "calendar"
        case .boolean: return "checkmark.square"
        }
    }
}

struct ColumnInfo: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    var name: String
    var kind: ColumnKind
    var sqlName: String { "c\(index)" }
}

struct SheetInfo: Identifiable, Hashable {
    let id: Int64
    let workbookID: Int64
    var name: String
    var tableName: String
    var rowCount: Int
    var columns: [ColumnInfo]
    var index: Int
    /// True when a `data_N_f` side table with per-cell fill colours exists.
    var hasColors: Bool = false

    var fillsTableName: String { tableName + "_f" }
}

struct WorkbookInfo: Identifiable, Hashable {
    let id: Int64
    var name: String
    var originalFileName: String
    var sizeBytes: Int64
    var importedAt: Date
    var sheets: [SheetInfo]

    var totalRows: Int { sheets.reduce(0) { $0 + $1.rowCount } }
}

/// Catalog of everything imported, persisted in the same SQLite file as the data.
final class Workspace: @unchecked Sendable {
    let db: Database
    static let shared: Workspace = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sheetx.sqlite")
        // A failure here is unrecoverable; fall back to a temp DB so the app still runs.
        if let db = try? Database(path: url.path), let ws = try? Workspace(db: db) { return ws }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sheetx-fallback.sqlite")
        try? FileManager.default.removeItem(at: tmp)
        // swiftlint:disable:next force_try
        return try! Workspace(db: try! Database(path: tmp.path))
    }()

    init(db: Database) throws {
        self.db = db
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta_workbooks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            file_name TEXT NOT NULL,
            size_bytes INTEGER NOT NULL DEFAULT 0,
            imported_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta_sheets(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            workbook_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            table_name TEXT NOT NULL,
            row_count INTEGER NOT NULL DEFAULT 0,
            sheet_index INTEGER NOT NULL DEFAULT 0,
            has_colors INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS meta_columns(
            sheet_id INTEGER NOT NULL,
            col_index INTEGER NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta_saved_queries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sheet_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta_reports(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sheet_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_sheets_wb ON meta_sheets(workbook_id);
        CREATE INDEX IF NOT EXISTS idx_cols_sheet ON meta_columns(sheet_id);
        """)

        // Added after the first release: per-sheet fill-colour flag.
        // ALTER fails once the column exists, which is fine.
        try? db.exec("ALTER TABLE meta_sheets ADD COLUMN has_colors INTEGER NOT NULL DEFAULT 0;")
    }

    // MARK: - Reading catalog

    func loadWorkbooks() throws -> [WorkbookInfo] {
        let wbRows = try db.query("SELECT id,name,file_name,size_bytes,imported_at FROM meta_workbooks ORDER BY imported_at DESC")
        var result: [WorkbookInfo] = []
        for r in wbRows {
            guard case .int(let id) = r[0] else { continue }
            let sheets = try loadSheets(workbookID: id)
            result.append(WorkbookInfo(
                id: id,
                name: r[1].stringValue,
                originalFileName: r[2].stringValue,
                sizeBytes: Int64(r[3].doubleValue ?? 0),
                importedAt: Date(timeIntervalSince1970: r[4].doubleValue ?? 0),
                sheets: sheets))
        }
        return result
    }

    func loadSheets(workbookID: Int64) throws -> [SheetInfo] {
        let rows = try db.query(
            "SELECT id,name,table_name,row_count,sheet_index,has_colors FROM meta_sheets WHERE workbook_id=? ORDER BY sheet_index",
            [.int(workbookID)])
        return try rows.compactMap { r in
            guard case .int(let sid) = r[0] else { return nil }
            return SheetInfo(
                id: sid,
                workbookID: workbookID,
                name: r[1].stringValue,
                tableName: r[2].stringValue,
                rowCount: Int(r[3].doubleValue ?? 0),
                columns: try loadColumns(sheetID: sid),
                index: Int(r[4].doubleValue ?? 0),
                hasColors: r.count > 5 && (r[5].doubleValue ?? 0) > 0)
        }
    }

    func loadColumns(sheetID: Int64) throws -> [ColumnInfo] {
        let rows = try db.query("SELECT col_index,name,kind FROM meta_columns WHERE sheet_id=? ORDER BY col_index", [.int(sheetID)])
        return rows.map { r in
            ColumnInfo(index: Int(r[0].doubleValue ?? 0),
                       name: r[1].stringValue,
                       kind: ColumnKind(rawValue: r[2].stringValue) ?? .text)
        }
    }

    // MARK: - Writing catalog

    func createWorkbook(name: String, fileName: String, size: Int64) throws -> Int64 {
        try db.run("INSERT INTO meta_workbooks(name,file_name,size_bytes,imported_at) VALUES(?,?,?,?)",
                   [.text(name), .text(fileName), .int(size), .double(Date().timeIntervalSince1970)])
        return db.lastInsertRowID()
    }

    func createSheet(workbookID: Int64, name: String, index: Int) throws -> Int64 {
        try db.run("INSERT INTO meta_sheets(workbook_id,name,table_name,row_count,sheet_index) VALUES(?,?,?,0,?)",
                   [.int(workbookID), .text(name), .text(""), .int(Int64(index))])
        let id = db.lastInsertRowID()
        try db.run("UPDATE meta_sheets SET table_name=? WHERE id=?", [.text("data_\(id)"), .int(id)])
        return id
    }

    func saveColumns(sheetID: Int64, columns: [ColumnInfo]) throws {
        try db.run("DELETE FROM meta_columns WHERE sheet_id=?", [.int(sheetID)])
        for c in columns {
            try db.run("INSERT INTO meta_columns(sheet_id,col_index,name,kind) VALUES(?,?,?,?)",
                       [.int(sheetID), .int(Int64(c.index)), .text(c.name), .text(c.kind.rawValue)])
        }
    }

    func setRowCount(sheetID: Int64, count: Int) throws {
        try db.run("UPDATE meta_sheets SET row_count=? WHERE id=?", [.int(Int64(count)), .int(sheetID)])
    }

    func setHasColors(sheetID: Int64, _ on: Bool) throws {
        try db.run("UPDATE meta_sheets SET has_colors=? WHERE id=?",
                   [.int(on ? 1 : 0), .int(sheetID)])
    }

    func deleteWorkbook(_ id: Int64) throws {
        let sheets = try loadSheets(workbookID: id)
        for s in sheets {
            try? db.exec("DROP TABLE IF EXISTS \(s.tableName.sqlIdentifier);")
            try? db.exec("DROP TABLE IF EXISTS \((s.tableName + "_fts").sqlIdentifier);")
            try? db.exec("DROP TABLE IF EXISTS \(s.fillsTableName.sqlIdentifier);")
            try db.run("DELETE FROM meta_columns WHERE sheet_id=?", [.int(s.id)])
            try db.run("DELETE FROM meta_reports WHERE sheet_id=?", [.int(s.id)])
            try db.run("DELETE FROM meta_saved_queries WHERE sheet_id=?", [.int(s.id)])
        }
        try db.run("DELETE FROM meta_sheets WHERE workbook_id=?", [.int(id)])
        try db.run("DELETE FROM meta_workbooks WHERE id=?", [.int(id)])
        try? db.exec("VACUUM;")
    }

    func renameSheet(_ sheetID: Int64, to name: String) throws {
        try db.run("UPDATE meta_sheets SET name=? WHERE id=?", [.text(name), .int(sheetID)])
    }

    // MARK: - Reports

    func saveReport(sheetID: Int64, title: String, body: String) throws {
        try db.run("INSERT INTO meta_reports(sheet_id,title,body,created_at) VALUES(?,?,?,?)",
                   [.int(sheetID), .text(title), .text(body), .double(Date().timeIntervalSince1970)])
    }

    struct StoredReport: Identifiable, Hashable {
        let id: Int64
        let sheetID: Int64
        let title: String
        let body: String
        let createdAt: Date
    }

    func loadReports() throws -> [StoredReport] {
        let rows = try db.query("SELECT id,sheet_id,title,body,created_at FROM meta_reports ORDER BY created_at DESC LIMIT 200")
        return rows.compactMap { r in
            guard case .int(let id) = r[0], case .int(let sid) = r[1] else { return nil }
            return StoredReport(id: id, sheetID: sid, title: r[2].stringValue, body: r[3].stringValue,
                                createdAt: Date(timeIntervalSince1970: r[4].doubleValue ?? 0))
        }
    }

    func deleteReport(_ id: Int64) throws {
        try db.run("DELETE FROM meta_reports WHERE id=?", [.int(id)])
    }
}
