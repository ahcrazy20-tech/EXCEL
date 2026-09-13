import Foundation
@testable import SheetX

final class AnalysisFixture {
    let directory: URL
    let db: Database
    let workspace: Workspace
    let sheet: SheetInfo

    init(rows: [[DBValue]] = [[.text("A"), .int(10)], [.text(""), .text("oops")], [.null, .int(30)]]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent("test.sqlite").path)
        workspace = try Workspace(db: db)
        let workbookID = try workspace.createWorkbook(name: "Test", fileName: "test.csv", size: 0)
        let sheetID = try workspace.createSheet(workbookID: workbookID, name: "Data", index: 0)
        let columns = [ColumnInfo(index: 0, name: "Category", kind: .text),
                       ColumnInfo(index: 1, name: "Amount", kind: .number)]
        try workspace.saveColumns(sheetID: sheetID, columns: columns)
        try workspace.setRowCount(sheetID: sheetID, count: rows.count)
        sheet = SheetInfo(id: sheetID, workbookID: workbookID, name: "Data", tableName: "data_\(sheetID)",
                          rowCount: rows.count, columns: columns, index: 0)
        try db.exec("CREATE TABLE \(sheet.tableName.sqlIdentifier)(c0 TEXT,c1);")
        var position = 0
        try db.bulkInsert(sql: "INSERT INTO \(sheet.tableName.sqlIdentifier) VALUES(?,?)") {
            guard position < rows.count else { return nil }
            defer { position += 1 }
            return rows[position]
        }
    }

    func reader(timeout: TimeInterval = 15, cancellation: QueryCancellation = QueryCancellation(),
                maxRows: Int = 10_000, maxBytes: Int = 4 * 1024 * 1024) throws -> Database {
        try Database(path: db.path, analysisPolicy: AnalysisQueryPolicy(
            tableName: sheet.tableName, cancellation: cancellation, timeout: timeout,
            maxRows: maxRows, maxBytes: maxBytes))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
