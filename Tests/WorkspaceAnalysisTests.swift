import XCTest
@testable import SheetX

final class WorkspaceAnalysisTests: XCTestCase {
    func testSaveReloadRenameDeleteAndOfflineReplay() async throws {
        let fixture = try AnalysisFixture()
        var plan = CommandPlan()
        plan.analysis.query.filters = [FilterCondition(columnIndex: 0, op: .equals, value: "A")]
        let recipe = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows where Category equals A", plan: plan)
        try fixture.workspace.saveAnalysis(title: "  My analysis  ", recipe: recipe, sheet: fixture.sheet)
        let entries = try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "My analysis")
        let reloaded = try XCTUnwrap(entries[0].recipe)
        XCTAssertEqual(reloaded.plan, plan)
        try reloaded.validate(for: fixture.sheet)
        let output = try await AnalysisRunner.execute(plan: reloaded.plan, path: fixture.db.path,
                                                      sheet: fixture.sheet, arabic: false)
        XCTAssertEqual(output.table?.rows, [[.text("A"), .int(10)]])
        try fixture.workspace.renameAnalysis(id: entries[0].id, sheetID: fixture.sheet.id, title: "Renamed")
        XCTAssertEqual(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id)[0].title, "Renamed")
        try fixture.workspace.deleteAnalysis(id: entries[0].id, sheetID: fixture.sheet.id)
        XCTAssertTrue(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).isEmpty)
    }

    func testRecipeRejectsSchemaOrSourceChanges() throws {
        let fixture = try AnalysisFixture()
        let recipe = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows", plan: CommandPlan())
        var changed = fixture.sheet
        changed.columns[0].name = "Different"
        XCTAssertThrowsError(try recipe.validate(for: changed))
        changed = fixture.sheet
        changed.rowCount += 1
        XCTAssertThrowsError(try recipe.validate(for: changed))
        changed = fixture.sheet
        changed.tableName = "data_other"
        XCTAssertThrowsError(try recipe.validate(for: changed))
    }

    func testInvalidColumnsAreRejectedInsteadOfDroppingFilters() throws {
        let fixture = try AnalysisFixture()
        var plan = CommandPlan()
        plan.analysis.query.filters = [FilterCondition(columnIndex: 100, op: .equals, value: "secret")]
        XCTAssertThrowsError(try plan.validate(for: fixture.sheet))
        XCTAssertThrowsError(try AIClient.decodePlan(
            #"{"kind":"filterRows","filters":[{"columnIndex":100,"op":"equals","value":"secret"}]}"#,
            sheet: fixture.sheet, fallbackCommand: "test"))
        XCTAssertThrowsError(try AIClient.decodePlan(#"{"kind":"sql","sql":""}"#,
                                                   sheet: fixture.sheet, fallbackCommand: "test"))
        XCTAssertThrowsError(try AIClient.decodePlan(#"{"kind":"unknown"}"#,
                                                   sheet: fixture.sheet, fallbackCommand: "test"))
    }

    func testCorruptPayloadStaysVisibleAndDeletable() throws {
        let fixture = try AnalysisFixture()
        try fixture.db.run("INSERT INTO meta_saved_queries(sheet_id,title,payload,created_at) VALUES(?,?,?,?)",
                           [.int(fixture.sheet.id), .text("Old analysis"), .text("not json"), .int(1)])
        let list = try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id)
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].recipe)
        try fixture.workspace.deleteAnalysis(id: list[0].id, sheetID: fixture.sheet.id)
        XCTAssertTrue(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).isEmpty)
    }

    func testDeleteSourceRemovesItsAnalysesAndRefusesOrphanSave() throws {
        let fixture = try AnalysisFixture()
        let recipe = SavedAnalysisRecipe(sheet: fixture.sheet, command: "Rows", plan: CommandPlan())
        try fixture.workspace.saveAnalysis(title: "Rows", recipe: recipe, sheet: fixture.sheet)
        try fixture.workspace.deleteWorkbook(fixture.sheet.workbookID)
        XCTAssertTrue(try fixture.workspace.loadAnalyses(sheetID: fixture.sheet.id).isEmpty)
        XCTAssertThrowsError(try fixture.workspace.saveAnalysis(title: "Orphan", recipe: recipe, sheet: fixture.sheet))
    }

    func testDuplicateAnalysisHonorsFilters() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(1)], [.text("A"), .int(1)],
                                                [.text("B"), .int(1)], [.text("B"), .int(1)]])
        let query = QuerySpec(filters: [FilterCondition(columnIndex: 0, op: .equals, value: "A")])
        let table = try QueryEngine(db: fixture.db, sheet: fixture.sheet).duplicateGroups(columns: [0], query: query)
        XCTAssertEqual(table.rows, [[.text("A"), .int(2)]])
    }

    func testMedianIsNotSilentlyReportedAsAverage() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(1)], [.text("A"), .int(2)], [.text("A"), .int(99)]])
        let engine = QueryEngine(db: fixture.db, sheet: fixture.sheet)
        var spec = AnalysisSpec(aggregations: [Aggregation(function: .median, columnIndex: 1)])
        XCTAssertEqual(try engine.runAnalysis(spec).rows[0][0].doubleValue, 2)
        spec.groupBy = [0]
        XCTAssertThrowsError(try engine.runAnalysis(spec))
    }
}
