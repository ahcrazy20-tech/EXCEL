import XCTest
@testable import SheetX

final class DashboardTests: XCTestCase {
    private func board(_ fixture: AnalysisFixture) -> DashboardRecipe {
        DashboardRecipe(source: PreparationSource(fixture.sheet), title: "Test", cards: [
            DashboardCard(title: "Rows"), DashboardCard(title: "Sum", metric: .sum, valueColumn: 1),
            DashboardCard(title: "Average", metric: .average, valueColumn: 1),
            DashboardCard(title: "Categories", display: .bar), DashboardCard(title: "Table", display: .table)
        ])
    }
    private func run(_ board: DashboardRecipe, _ fixture: AnalysisFixture) throws -> DashboardSnapshot {
        try DashboardRunner.run(board, sheet: fixture.sheet, path: fixture.db.path)
    }

    func testAllCardsShareFiltersAndIgnoreInvalidNumericText() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(10)], [.text("A"), .text("oops")], [.text("B"), .int(20)]])
        var recipe = board(fixture)
        recipe.query.filters = [FilterCondition(columnIndex: 0, op: .equals, value: "A")]
        let result = try run(recipe, fixture)
        XCTAssertEqual(result.matchingRows, 2)
        XCTAssertEqual(result.cards[0].table.rows, [[.int(2)]])
        XCTAssertEqual(result.cards[1].table.rows, [[.int(10)]])
        XCTAssertEqual(result.cards[2].table.rows, [[.double(10)]])
        XCTAssertEqual(result.cards[3].table.rows, [[.text("A"), .int(2)]])
        XCTAssertEqual(result.cards[4].table.rows.count, 2)
    }

    func testDrilldownAddsANDOutsideMatchAnyFilters() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(1)], [.text("B"), .int(2)], [.text("C"), .int(3)]])
        var recipe = board(fixture)
        recipe.query.join = .or
        recipe.query.filters = [FilterCondition(columnIndex: 0, op: .equals, value: "A"), FilterCondition(columnIndex: 0, op: .equals, value: "B")]
        recipe.selection = DashboardSelection(column: 0, value: .text("B"))
        XCTAssertEqual(try run(recipe, fixture).matchingRows, 1)
        recipe.selection = DashboardSelection(column: 0, value: .text("C"))
        XCTAssertEqual(try run(recipe, fixture).matchingRows, 0)
        recipe.selection = nil
        XCTAssertEqual(try run(recipe, fixture).matchingRows, 2)
    }

    func testDrilldownKeepsTextNumericNullAndEmptyGroupsDistinct() throws {
        let fixture = try AnalysisFixture(rows: [[.text("a"), .text("1")], [.text("b"), .int(1)], [.text("c"), .null], [.text("d"), .text("")]])
        var recipe = board(fixture)
        for value in [DBValue.text("1"), .int(1), .null, .text("")] {
            recipe.selection = DashboardSelection(column: 1, value: value)
            XCTAssertEqual(try run(recipe, fixture).matchingRows, 1)
        }
        recipe.selection = DashboardSelection(column: 1, value: .text("001"))
        XCTAssertEqual(try run(recipe, fixture).matchingRows, 0)
    }

    func testDrilldownQuotesAndSQLLookingValuesAreOnlyBoundData() throws {
        let text = "x' OR 1=1; DROP TABLE meta_sheets; --"
        let fixture = try AnalysisFixture(rows: [[.text(text), .int(1)], [.text("B"), .int(2)]])
        var recipe = board(fixture); recipe.selection = DashboardSelection(column: 0, value: .text(text))
        XCTAssertEqual(try run(recipe, fixture).matchingRows, 1)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_sheets"), .int(1))
    }

    func testNoMatchingRowsHaveCountZeroAndNullNumericMetrics() throws {
        let fixture = try AnalysisFixture()
        var recipe = board(fixture); recipe.query.search = "not present"
        let result = try run(recipe, fixture)
        XCTAssertEqual(result.matchingRows, 0)
        XCTAssertEqual(result.cards[0].table.rows, [[.int(0)]])
        XCTAssertEqual(result.cards[1].table.rows, [[.null]])
        XCTAssertEqual(result.cards[2].table.rows, [[.null]])
        XCTAssertTrue(result.cards[3].table.rows.isEmpty)
        XCTAssertTrue(result.cards[4].table.rows.isEmpty)
    }

    func testBarsLinesAndTablesHaveExplicitBounds() throws {
        let fixture = try AnalysisFixture(rows: (0..<70).map { [.text(String(format: "%03d", $0)), .int(Int64($0))] })
        var recipe = board(fixture)
        recipe.cards.append(DashboardCard(title: "Line", display: .line))
        let result = try run(recipe, fixture)
        XCTAssertEqual(result.matchingRows, 70)
        XCTAssertEqual(result.cards[3].table.rows.count, 12)
        XCTAssertEqual(result.cards[4].table.rows.count, 50)
        XCTAssertEqual(result.cards[5].table.rows.count, 24)
        XCTAssertTrue(result.cards[3].table.truncated)
        XCTAssertTrue(result.cards[4].table.truncated)
        XCTAssertTrue(result.cards[5].table.truncated)
        XCTAssertEqual(result.cards[5].table.rows.first?[0], .text("000"))
    }

    func testSaveReloadEditAndResetAreConfigurationOnly() throws {
        let fixture = try AnalysisFixture()
        var recipe = board(fixture)
        recipe.selection = DashboardSelection(column: 1, value: .int(10))
        try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet)
        XCTAssertEqual(try fixture.workspace.dashboard(sheetID: fixture.sheet.id), recipe)
        recipe.cards.swapAt(0, 1); recipe.title = "Changed"
        try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet)
        XCTAssertEqual(try fixture.workspace.loadDashboards().count, 1)
        XCTAssertEqual(try fixture.workspace.loadDashboards().first?.title, "Changed")
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
        try fixture.workspace.deleteDashboard(sheetID: fixture.sheet.id)
        XCTAssertNil(try fixture.workspace.dashboard(sheetID: fixture.sheet.id))
    }

    func testSourceDeletionCleansOnlyItsDashboardAndRefusesOrphanSave() throws {
        let fixture = try AnalysisFixture()
        let recipe = board(fixture)
        try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet)
        try fixture.db.run("INSERT INTO meta_dashboards(sheet_id,title,payload) VALUES(999,'Other','{}')")
        try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertNil(try fixture.workspace.dashboard(sheetID: fixture.sheet.id))
        XCTAssertEqual(try fixture.workspace.loadDashboards().map(\.id), [999])
        XCTAssertThrowsError(try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet))
        XCTAssertThrowsError(try run(recipe, fixture))
    }

    func testInvalidRecipesCannotDropBadFiltersOrAccessOtherTables() throws {
        let fixture = try AnalysisFixture()
        var recipe = board(fixture); recipe.version = 99
        XCTAssertThrowsError(try run(recipe, fixture))
        recipe = board(fixture); recipe.cards[0].metric = .sum; recipe.cards[0].valueColumn = 99
        XCTAssertThrowsError(try run(recipe, fixture))
        recipe = board(fixture); recipe.query.filters = [FilterCondition(columnIndex: 100, value: "x")]
        XCTAssertThrowsError(try run(recipe, fixture))
        recipe = board(fixture); recipe.selection = DashboardSelection(column: 100, value: .text("x"))
        XCTAssertThrowsError(try run(recipe, fixture))
        recipe = board(fixture); recipe.cards = (0..<13).map { DashboardCard(title: "\($0)") }
        XCTAssertThrowsError(try run(recipe, fixture))
        recipe = board(fixture); recipe.query.filters = [FilterCondition(columnIndex: 0, op: .regex, value: "x")]
        XCTAssertThrowsError(try run(recipe, fixture))
    }

    func testSchemaChangeAndCorruptSavedPayloadAreVisibleErrors() throws {
        let fixture = try AnalysisFixture()
        let recipe = board(fixture)
        var changed = fixture.sheet; changed.columns[0].name = "Changed"
        XCTAssertThrowsError(try recipe.validate(for: changed))
        try fixture.db.run("INSERT INTO meta_dashboards(sheet_id,title,payload) VALUES(?,'Bad','not json')", [.int(fixture.sheet.id)])
        XCTAssertThrowsError(try fixture.workspace.dashboard(sheetID: fixture.sheet.id))
        XCTAssertNil(try fixture.workspace.loadDashboards().first?.recipe)
    }

    func testCancellationDoesNotModifySourceOrReturnPartialCards() throws {
        let fixture = try AnalysisFixture()
        let cancellation = QueryCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try DashboardRunner.run(board(fixture), sheet: fixture.sheet, path: fixture.db.path, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testSaveFailureRollsBackPreviousConfiguration() throws {
        let fixture = try AnalysisFixture()
        var recipe = board(fixture)
        try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet)
        try fixture.db.exec("CREATE TRIGGER reject_dashboard BEFORE UPDATE ON meta_dashboards BEGIN SELECT RAISE(ABORT,'test'); END;")
        recipe.title = "Do not save"
        XCTAssertThrowsError(try fixture.workspace.saveDashboard(recipe, sheet: fixture.sheet))
        XCTAssertEqual(try fixture.workspace.dashboard(sheetID: fixture.sheet.id)?.title, "Test")
    }
}
