import XCTest
@testable import SheetX

final class SheetDeletionTests: XCTestCase {
    private func sibling(in fixture: AnalysisFixture) throws -> Int64 {
        let id = try fixture.workspace.createSheet(workbookID: fixture.sheet.workbookID, name: "Keep me", index: 1)
        try fixture.db.exec("CREATE TABLE data_\(id)(c0 TEXT); INSERT INTO data_\(id) VALUES('keep');")
        try fixture.workspace.saveColumns(sheetID: id, columns: [ColumnInfo(index: 0, name: "Keep", kind: .text)])
        try fixture.workspace.setRowCount(sheetID: id, count: 1)
        try fixture.workspace.saveReport(sheetID: id, title: "Keep report", body: "Keep body")
        return id
    }

    func testSingleSheetDeletePreservesSiblingAndCleansDependentData() throws {
        let fixture = try AnalysisFixture()
        let keep = try sibling(in: fixture)
        let id = fixture.sheet.id
        try fixture.db.exec("CREATE TABLE data_\(id)_f(rowid INTEGER,f TEXT); CREATE TABLE data_\(id)_fts(value TEXT);")
        try fixture.workspace.saveReport(sheetID: id, title: "Remove report", body: "body")
        let recipe = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows", plan: CommandPlan())
        try fixture.workspace.saveAnalysis(title: "Remove analysis", recipe: recipe, sheet: fixture.sheet)
        // Populate the statement cache before dropping a previously queried table.
        _ = try fixture.db.query("SELECT * FROM data_\(id)")
        XCTAssertEqual(try fixture.workspace.deleteSheet(id, workbookID: fixture.sheet.workbookID), [id])
        XCTAssertEqual(try fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).map(\.id), [keep])
        XCTAssertEqual(try fixture.db.scalar("SELECT c0 FROM data_\(keep)"), .text("keep"))
        XCTAssertEqual(try fixture.workspace.loadReports().map(\.title), ["Keep report"])
        XCTAssertTrue(try fixture.workspace.loadAnalyses(sheetID: id).isEmpty)
        XCTAssertTrue(try fixture.workspace.loadColumns(sheetID: id).isEmpty)
        for name in ["data_\(id)", "data_\(id)_f", "data_\(id)_fts"] {
            XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name=?", [.text(name)]), .int(0))
        }
        XCTAssertEqual(try fixture.workspace.loadWorkbooks().count, 1)
    }

    func testDeletingLastSheetRemovesEmptyWorkbookAndIsIdempotent() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
        XCTAssertNoThrow(try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID))
        XCTAssertThrowsError(try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Late report", body: "body"))
    }

    func testFailedDeleteRollsBackTablesAndMetadata() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Keep", body: "Keep")
        try fixture.db.exec("""
            CREATE TRIGGER reject_deletion BEFORE DELETE ON meta_sheets BEGIN
            SELECT RAISE(ABORT,'simulated failure'); END;
            """)
        XCTAssertThrowsError(try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
        XCTAssertEqual(try fixture.workspace.loadReports().count, 1)
        XCTAssertEqual(try fixture.workspace.loadColumns(sheetID: fixture.sheet.id).count, 2)
        XCTAssertEqual(try fixture.workspace.loadWorkbooks().count, 1)
    }

    func testWrongWorkbookOrCorruptTableIdentityCannotDeleteAnotherSheet() throws {
        let fixture = try AnalysisFixture()
        let keep = try sibling(in: fixture)
        XCTAssertThrowsError(try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: 999))
        try fixture.db.run("UPDATE meta_sheets SET table_name=? WHERE id=?", [.text("data_\(keep)"), .int(fixture.sheet.id)])
        XCTAssertThrowsError(try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID))
        XCTAssertEqual(try fixture.db.scalar("SELECT c0 FROM data_\(keep)"), .text("keep"))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testDeletionCannotJoinAnActiveImportTransaction() throws {
        let fixture = try AnalysisFixture()
        try fixture.db.exec("BEGIN IMMEDIATE;")
        defer { try? fixture.db.exec("ROLLBACK;") }
        XCTAssertThrowsError(try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testEntireWorkbookDeletionStillRemovesAllItsSheets() throws {
        let fixture = try AnalysisFixture()
        let keep = try sibling(in: fixture)
        let removed = try fixture.workspace.deleteWorkbook(fixture.sheet.workbookID)
        XCTAssertEqual(Set(removed), Set([fixture.sheet.id, keep]))
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
        XCTAssertTrue(try fixture.workspace.loadReports().isEmpty)
        XCTAssertThrowsError(try fixture.db.query("SELECT * FROM data_\(keep)"))
    }

    @MainActor
    func testLayoutCleanupDoesNotRemoveOtherSheetsPreferences() throws {
        let name = "SheetDeletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["1": ["hidden": [0]], "2": ["hidden": [1]]], forKey: "sheetLayouts")
        SheetViewModel.removeLayouts(for: [1], defaults: defaults)
        let remaining = try XCTUnwrap(defaults.dictionary(forKey: "sheetLayouts"))
        XCTAssertNil(remaining["1"])
        XCTAssertNotNil(remaining["2"])
    }
}
