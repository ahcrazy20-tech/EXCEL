import XCTest
@testable import SheetX

final class TrashTests: XCTestCase {
    private func sibling(_ fixture: AnalysisFixture) throws -> SheetInfo {
        let id = try fixture.workspace.createSheet(workbookID: fixture.sheet.workbookID, name: "Sibling", index: 1)
        try fixture.db.exec("CREATE TABLE data_\(id)(c0 TEXT,c1); INSERT INTO data_\(id) VALUES('Keep',5)")
        try fixture.workspace.saveColumns(sheetID: id, columns: fixture.sheet.columns)
        try fixture.workspace.setRowCount(sheetID: id, count: 1)
        return SheetInfo(id: id, workbookID: fixture.sheet.workbookID, name: "Sibling", tableName: "data_\(id)", rowCount: 1, columns: fixture.sheet.columns, index: 1)
    }

    private func entry(_ fixture: AnalysisFixture, id: Int64? = nil) throws -> TrashedSheet {
        try XCTUnwrap(fixture.workspace.loadTrash().first { $0.sheetID == (id ?? fixture.sheet.id) })
    }

    func testTrashHidesOneSheetButPreservesDataColorsAndSavedWork() throws {
        let fixture = try AnalysisFixture()
        let keep = try sibling(fixture)
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Report", body: "body")
        let analysis = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows", plan: CommandPlan())
        try fixture.workspace.saveAnalysis(title: "Saved", recipe: analysis, sheet: fixture.sheet)
        try fixture.workspace.saveDashboard(.starter(sheet: fixture.sheet), sheet: fixture.sheet)
        try fixture.db.exec("CREATE TABLE \(fixture.sheet.fillsTableName)(rowid INTEGER PRIMARY KEY,f TEXT); INSERT INTO \(fixture.sheet.fillsTableName) VALUES(0,'0:FF0000FF'),(1,'1:FFFF0000');")
        try fixture.workspace.setHasColors(sheetID: fixture.sheet.id, true)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertEqual(try fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).map(\.id), [keep.id])
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.fillsTableName)"), .int(2))
        XCTAssertTrue(try fixture.workspace.loadReports().isEmpty)
        XCTAssertTrue(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).isEmpty)
        XCTAssertTrue(try fixture.workspace.loadDashboards().isEmpty)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_reports"), .int(1))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_saved_queries"), .int(1))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_dashboards"), .int(1))
        try fixture.workspace.restoreSheet(entry(fixture))
        let restored = try XCTUnwrap(fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).first)
        XCTAssertEqual(restored.id, fixture.sheet.id)
        XCTAssertTrue(restored.hasColors)
        XCTAssertEqual(try fixture.workspace.loadReports().count, 1)
        XCTAssertEqual(try fixture.workspace.loadAnalyses(sheetID: restored.id).count, 1)
        XCTAssertEqual(try fixture.workspace.loadDashboards().count, 1)
        XCTAssertEqual(try fixture.workspace.trashCount(), 0)
    }

    func testLastSheetHidesWorkbookAndRestoreReturnsOriginalIdentity() throws {
        let fixture = try AnalysisFixture()
        let original = try XCTUnwrap(fixture.workspace.loadWorkbooks().first)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_workbooks"), .int(1))
        try fixture.workspace.restoreSheet(entry(fixture))
        let restored = try XCTUnwrap(fixture.workspace.loadWorkbooks().first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.importedAt, original.importedAt)
        XCTAssertEqual(restored.sheets.map(\.id), [fixture.sheet.id])
    }

    func testWorkbookTrashLeavesPreviousTrashTokenUnchanged() throws {
        let fixture = try AnalysisFixture()
        let second = try sibling(fixture)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let first = try entry(fixture)
        XCTAssertEqual(try fixture.workspace.trashWorkbook(fixture.sheet.workbookID), [second.id])
        XCTAssertEqual(try entry(fixture).id, first.id)
        XCTAssertEqual(try entry(fixture).deletedAt, first.deletedAt)
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
        try fixture.workspace.restoreSheet(entry(fixture, id: second.id))
        XCTAssertEqual(try fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).map(\.id), [second.id])
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
    }

    func testRepeatedTrashDoesNotResetRetentionTokenOrTime() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let before = try entry(fixture)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertEqual(try entry(fixture).id, before.id)
        XCTAssertEqual(try entry(fixture).deletedAt, before.deletedAt)
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
    }

    func testStaleConfirmationCannotDeleteActiveSheetOrLaterTrashCycle() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let old = try entry(fixture)
        try fixture.workspace.restoreSheet(old)
        XCTAssertThrowsError(try fixture.workspace.permanentlyDelete(old))
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let current = try entry(fixture)
        XCTAssertNotEqual(current.id, old.id)
        XCTAssertThrowsError(try fixture.workspace.permanentlyDelete(old))
        XCTAssertThrowsError(try fixture.workspace.restoreSheet(old))
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testNewAnalysisAndDashboardJobsRequireRestore() throws {
        let fixture = try AnalysisFixture()
        let openReader = try fixture.reader()
        let recipe = DashboardRecipe.starter(sheet: fixture.sheet)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertThrowsError(try fixture.reader())
        XCTAssertThrowsError(try DashboardRunner.run(recipe, sheet: fixture.sheet, path: fixture.db.path))
        // In-flight read snapshots are not a deletion/security boundary.
        XCTAssertEqual(try openReader.scalar("SELECT COUNT(*) FROM main.\(fixture.sheet.tableName.sqlIdentifier)"), .int(3))
        try fixture.workspace.restoreSheet(entry(fixture))
        XCTAssertEqual(try DashboardRunner.run(recipe, sheet: fixture.sheet, path: fixture.db.path).matchingRows, 3)
    }

    func testTrustedTrashSetupStatementsCannotBypassAIAuthorizerCache() throws {
        let fixture = try AnalysisFixture()
        let reader = try fixture.reader()
        XCTAssertThrowsError(try reader.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='meta_sheet_trash'"))
        XCTAssertThrowsError(try reader.scalar("SELECT COUNT(*) FROM meta_sheet_trash WHERE sheet_id=?", [.int(fixture.sheet.id)]))
        XCTAssertThrowsError(try reader.scalar("SELECT * FROM meta_sheet_trash"))
        XCTAssertEqual(try reader.scalar("SELECT COUNT(*) FROM main.\(fixture.sheet.tableName.sqlIdentifier)"), .int(3))
    }

    func testPreparationRefusesTrashedSourcesAndRestoresRebuildability() throws {
        let fixture = try AnalysisFixture()
        let recipe = PreparationRecipe(operation: .clean(CleaningRecipe(source: PreparationSource(fixture.sheet), steps: [])))
        let preview = try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertThrowsError(try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path))
        XCTAssertThrowsError(try PreparationEngine.publish(preview, name: "Copy", workspacePath: fixture.db.path, approveDuplicates: false, approveInvalid: false))
        try fixture.workspace.restoreSheet(entry(fixture))
        XCTAssertEqual(try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path).summary.outputRows, 3)
    }

    func testDerivedHistorySurvivesTrashAndSourcePurge() throws {
        let fixture = try AnalysisFixture()
        let recipe = PreparationRecipe(operation: .clean(CleaningRecipe(source: PreparationSource(fixture.sheet), steps: [])))
        let preview = try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path)
        let result = try XCTUnwrap(PreparationEngine.publish(preview, name: "Copy", workspacePath: fixture.db.path, approveDuplicates: false, approveInvalid: false).sheets.first)
        try fixture.workspace.trashSheet(result.id, workbookID: result.workbookID)
        XCTAssertEqual(try fixture.workspace.preparation(sheetID: result.id)?.recipe, recipe)
        try fixture.workspace.restoreSheet(entry(fixture, id: result.id))
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        try fixture.workspace.permanentlyDelete(entry(fixture))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(result.tableName)"), .int(3))
        XCTAssertNotNil(try fixture.workspace.preparation(sheetID: result.id))
        XCTAssertThrowsError(try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path))
    }

    func testPurgeDeletesDataMetadataAndOnlyFinalWorkbook() throws {
        let fixture = try AnalysisFixture()
        let second = try sibling(fixture)
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "R", body: "B")
        try fixture.workspace.saveDashboard(.starter(sheet: fixture.sheet), sheet: fixture.sheet)
        try fixture.db.exec("CREATE TABLE \(fixture.sheet.fillsTableName)(rowid INTEGER PRIMARY KEY,f TEXT); CREATE TABLE \(fixture.sheet.tableName)_fts(v TEXT)")
        try fixture.workspace.trashWorkbook(fixture.sheet.workbookID)
        try fixture.workspace.permanentlyDelete(entry(fixture))
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_workbooks"), .int(1))
        for table in [fixture.sheet.tableName, fixture.sheet.fillsTableName, fixture.sheet.tableName + "_fts"] {
            XCTAssertThrowsError(try fixture.db.scalar("SELECT COUNT(*) FROM \(table)"))
        }
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_reports"), .int(0))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_dashboards"), .int(0))
        try fixture.workspace.permanentlyDelete(entry(fixture, id: second.id))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_workbooks"), .int(0))
        XCTAssertEqual(try fixture.workspace.trashCount(), 0)
    }

    func testLateMetadataSavesCannotModifyTrashedWork() throws {
        let fixture = try AnalysisFixture()
        let analysis = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows", plan: CommandPlan())
        try fixture.workspace.saveAnalysis(title: "Keep", recipe: analysis, sheet: fixture.sheet)
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Keep", body: "Body")
        let report = try XCTUnwrap(fixture.workspace.loadReports().first)
        let saved = try XCTUnwrap(fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).first)
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertThrowsError(try fixture.workspace.saveAnalysis(title: "Late", recipe: analysis, sheet: fixture.sheet))
        XCTAssertThrowsError(try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Late", body: "Late"))
        XCTAssertThrowsError(try fixture.workspace.saveDashboard(.starter(sheet: fixture.sheet), sheet: fixture.sheet))
        try fixture.workspace.deleteAnalysis(id: saved.id, sheetID: fixture.sheet.id)
        try fixture.workspace.deleteReport(report.id)
        try fixture.workspace.restoreSheet(entry(fixture))
        XCTAssertEqual(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).first?.title, "Keep")
        XCTAssertEqual(try fixture.workspace.loadReports().first?.title, "Keep")
    }

    func testTrashAllIsAtomicAndRetainsExistingTrash() throws {
        let fixture = try AnalysisFixture()
        let second = try sibling(fixture)
        let otherWorkbook = try fixture.workspace.createWorkbook(name: "Other", fileName: "other.csv", size: 0)
        let third = try fixture.workspace.createSheet(workbookID: otherWorkbook, name: "Third", index: 0)
        try fixture.db.exec("CREATE TABLE data_\(third)(c0)")
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let token = try entry(fixture).id
        XCTAssertEqual(Set(try fixture.workspace.trashAllSheets()), Set([second.id, third]))
        XCTAssertEqual(try entry(fixture).id, token)
        XCTAssertEqual(try fixture.workspace.trashCount(), 3)
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
    }

    func testWorkbookTrashRollbackRestoresAllVisibility() throws {
        let fixture = try AnalysisFixture()
        _ = try sibling(fixture)
        try fixture.db.exec("CREATE TRIGGER reject_trash BEFORE INSERT ON meta_sheet_trash WHEN (SELECT COUNT(*) FROM meta_sheet_trash)=1 BEGIN SELECT RAISE(ABORT,'test'); END")
        XCTAssertThrowsError(try fixture.workspace.trashWorkbook(fixture.sheet.workbookID))
        XCTAssertEqual(try fixture.workspace.trashCount(), 0)
        XCTAssertEqual(try fixture.workspace.loadSheets(workbookID: fixture.sheet.workbookID).count, 2)
        XCTAssertThrowsError(try fixture.workspace.trashAllSheets())
        XCTAssertEqual(try fixture.workspace.trashCount(), 0)
    }

    func testRestoreRollbackKeepsTrashMarker() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        try fixture.db.exec("CREATE TRIGGER reject_restore BEFORE DELETE ON meta_sheet_trash BEGIN SELECT RAISE(ABORT,'test'); END")
        XCTAssertThrowsError(try fixture.workspace.restoreSheet(entry(fixture)))
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
        XCTAssertTrue(try fixture.workspace.loadWorkbooks().isEmpty)
    }

    func testPurgeFailureRollsBackDDLMetadataAndTrashEntry() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Keep", body: "Body")
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let before = try entry(fixture)
        try fixture.db.exec("CREATE TRIGGER reject_purge BEFORE DELETE ON meta_sheets BEGIN SELECT RAISE(ABORT,'test'); END")
        XCTAssertThrowsError(try fixture.workspace.permanentlyDelete(before))
        XCTAssertEqual(try entry(fixture).id, before.id)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_reports"), .int(1))
    }

    func testWrongOwnerCorruptIdentityAndMissingTableAreRefused() throws {
        let fixture = try AnalysisFixture()
        XCTAssertThrowsError(try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: 999))
        try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        let trashed = try entry(fixture)
        try fixture.db.run("UPDATE meta_sheets SET table_name='meta_workbooks' WHERE id=?", [.int(fixture.sheet.id)])
        XCTAssertThrowsError(try fixture.workspace.restoreSheet(trashed))
        XCTAssertThrowsError(try fixture.workspace.permanentlyDelete(trashed))
        try fixture.db.run("UPDATE meta_sheets SET table_name=? WHERE id=?", [.text(fixture.sheet.tableName), .int(fixture.sheet.id)])
        try fixture.db.exec("DROP TABLE \(fixture.sheet.tableName)")
        XCTAssertThrowsError(try fixture.workspace.restoreSheet(trashed))
        XCTAssertEqual(try fixture.workspace.trashCount(), 1)
    }

    func testTrashCannotJoinAnOpenImportTransaction() throws {
        let fixture = try AnalysisFixture()
        try fixture.db.exec("BEGIN IMMEDIATE")
        defer { try? fixture.db.exec("ROLLBACK") }
        XCTAssertThrowsError(try fixture.workspace.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID))
        XCTAssertThrowsError(try fixture.workspace.trashAllSheets())
        XCTAssertEqual(try fixture.workspace.trashCount(), 0)
    }

    func testUpgradeFromPreTrashSchemaPreservesExistingWork() throws {
        let fixture = try AnalysisFixture()
        try fixture.workspace.saveReport(sheetID: fixture.sheet.id, title: "Keep", body: "Body")
        try fixture.db.exec("DROP TABLE meta_sheet_trash")
        // Standalone pre-upgrade read-only analysis also tolerates the absent catalog.
        XCTAssertEqual(try fixture.reader().scalar("SELECT COUNT(*) FROM main.\(fixture.sheet.tableName.sqlIdentifier)"), .int(3))
        let upgraded = try Workspace(db: fixture.db)
        XCTAssertEqual(try upgraded.loadWorkbooks().first?.sheets.first?.id, fixture.sheet.id)
        XCTAssertEqual(try upgraded.loadReports().first?.title, "Keep")
        XCTAssertEqual(try upgraded.trashCount(), 0)
        try upgraded.trashSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        try upgraded.restoreSheet(entry(fixture))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testTrashPersistsAcrossConnectionsAndPaginationIsBounded() throws {
        let fixture = try AnalysisFixture()
        for index in 0..<55 {
            let id = try fixture.workspace.createSheet(workbookID: fixture.sheet.workbookID, name: "\(index)", index: index + 1)
            try fixture.db.exec("CREATE TABLE data_\(id)(c0)")
        }
        try fixture.workspace.trashAllSheets()
        let reopened = try Workspace(db: Database(path: fixture.db.path))
        XCTAssertEqual(try reopened.trashCount(), 56)
        let first = try reopened.loadTrash()
        let second = try reopened.loadTrash(offset: 50)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(second.count, 6)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        XCTAssertTrue(try reopened.loadWorkbooks().isEmpty)
    }
}
