import XCTest
@testable import SheetX

final class PreparationTests: XCTestCase {
    private func right(_ fixture: AnalysisFixture, rows: [[DBValue]]) throws -> SheetInfo {
        let wb = try fixture.workspace.createWorkbook(name: "Other workbook", fileName: "other.csv", size: 0)
        let id = try fixture.workspace.createSheet(workbookID: wb, name: "Reference", index: 0)
        let columns = [ColumnInfo(index: 0, name: "Key", kind: .text), ColumnInfo(index: 1, name: "Value", kind: .text)]
        try fixture.workspace.saveColumns(sheetID: id, columns: columns)
        try fixture.workspace.setRowCount(sheetID: id, count: rows.count)
        try fixture.db.exec("CREATE TABLE data_\(id)(c0,c1);")
        for row in rows { try fixture.db.run("INSERT INTO data_\(id) VALUES(?,?)", row) }
        return SheetInfo(id: id, workbookID: wb, name: "Reference", tableName: "data_\(id)", rowCount: rows.count, columns: columns, index: 0)
    }

    private func clean(_ fixture: AnalysisFixture, steps: [CleaningStep]) throws -> PreparationPreview {
        try PreparationEngine.prepare(PreparationRecipe(operation: .clean(CleaningRecipe(source: PreparationSource(fixture.sheet), steps: steps))), workspacePath: fixture.db.path)
    }

    private func join(_ fixture: AnalysisFixture, right: SheetInfo, mode: JoinMode = .left,
                      keys: JoinKeyMode = .exact, leftKey: Int = 0) throws -> PreparationPreview {
        let recipe = JoinRecipe(left: PreparationSource(fixture.sheet), right: PreparationSource(right), leftKey: leftKey,
                                rightKey: 0, mode: mode, keyMode: keys, rightColumns: [1])
        return try PreparationEngine.prepare(PreparationRecipe(operation: .join(recipe)), workspacePath: fixture.db.path)
    }

    private func publish(_ fixture: AnalysisFixture, _ preview: PreparationPreview,
                         duplicates: Bool = false, invalid: Bool = false) throws -> SheetInfo {
        let workbook = try PreparationEngine.publish(preview, name: "Prepared", workspacePath: fixture.db.path,
                                                     approveDuplicates: duplicates, approveInvalid: invalid)
        return try XCTUnwrap(workbook.sheets.first)
    }

    func testLeftJoinCountsDuplicatesAndUnmatchedBlankKeys() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .int(1)], [.text("A"), .int(2)], [.text("B"), .int(3)], [.text(" "), .int(4)], [.null, .int(5)]])
        let reference = try right(fixture, rows: [[.text("A"), .text("x")], [.text("A"), .text("y")], [.text("C"), .text("z")], [.text(""), .text("blank")], [.null, .text("null")]])
        let preview = try join(fixture, right: reference)
        let stats = try XCTUnwrap(preview.summary.join)
        XCTAssertEqual(stats.outputRows, 7)
        XCTAssertEqual(stats.matchedLeft, 2)
        XCTAssertEqual(stats.unmatchedLeft, 3)
        XCTAssertEqual(stats.unmatchedRight, 3)
        XCTAssertEqual(stats.blankLeftKeys, 2)
        XCTAssertEqual(stats.blankRightKeys, 2)
        XCTAssertEqual(stats.duplicateLeftKeys, 1)
        XCTAssertEqual(stats.duplicateRightKeys, 1)
        XCTAssertEqual(preview.after.rows.map { $0[2] }, [.text("x"), .text("y"), .text("x"), .text("y"), .null, .null, .null])
        XCTAssertThrowsError(try publish(fixture, preview))
        let result = try publish(fixture, preview, duplicates: true)
        XCTAssertEqual(result.rowCount, 7)
        XCTAssertTrue(result.isDerived)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(5))
    }

    func testInnerJoinDropsUnmatchedRows() throws {
        let fixture = try AnalysisFixture()
        let reference = try right(fixture, rows: [[.text("A"), .text("match")]])
        let preview = try join(fixture, right: reference, mode: .inner)
        XCTAssertEqual(preview.summary.outputRows, 1)
        XCTAssertEqual(preview.after.rows, [[.text("A"), .int(10), .text("match")]])
    }

    func testLookupRefusesAnyDuplicateNonblankRightKey() throws {
        let fixture = try AnalysisFixture()
        let reference = try right(fixture, rows: [[.text("Z"), .int(1)], [.text("Z"), .int(2)]])
        let preview = try join(fixture, right: reference, mode: .lookup)
        XCTAssertNil(preview.artifact)
        XCTAssertNotNil(preview.blockReason)
        XCTAssertThrowsError(try publish(fixture, preview, duplicates: true))
    }

    func testLookupAllowsRepeatedBlanksButNeverMatchesThem() throws {
        let fixture = try AnalysisFixture()
        let reference = try right(fixture, rows: [[.text("A"), .int(1)], [.null, .int(2)], [.text("\u{2003}"), .int(3)]])
        let preview = try join(fixture, right: reference, mode: .lookup)
        XCTAssertNotNil(preview.artifact)
        XCTAssertEqual(preview.after.rows.map { $0[2] }, [.int(1), .null, .null])
    }

    func testExactMatchingDistinguishesTextIDsAndNumericKeys() throws {
        let fixture = try AnalysisFixture(rows: [[.text("a"), .text("001")], [.text("b"), .text("1")], [.text("c"), .int(1)], [.text("d"), .double(1)]])
        let reference = try right(fixture, rows: [[.text("001"), .text("zero")], [.text("1"), .text("text")], [.double(1), .text("number")]])
        let preview = try join(fixture, right: reference, leftKey: 1)
        XCTAssertEqual(preview.after.rows.map { $0[2] }, [.text("zero"), .text("text"), .text("number"), .text("number")])
    }

    func testNormalizedMatchingIsExplicitAndReportsNewDuplicates() throws {
        let fixture = try AnalysisFixture(rows: [[.text(" A١ "), .int(1)]])
        let reference = try right(fixture, rows: [[.text("a1"), .int(10)], [.text("A۱"), .int(20)]])
        XCTAssertEqual(try join(fixture, right: reference).summary.join?.matchedLeft, 0)
        let normalized = try join(fixture, right: reference, keys: .normalizedText)
        XCTAssertEqual(normalized.summary.outputRows, 2)
        XCTAssertTrue(normalized.needsDuplicateApproval)
    }

    func testJoinExpansionIsBlockedBeforeMaterialization() throws {
        let rows = (0..<1001).map { _ in [DBValue.text("same"), .int(1)] }
        let fixture = try AnalysisFixture(rows: rows)
        let reference = try right(fixture, rows: rows)
        let preview = try join(fixture, right: reference)
        XCTAssertEqual(preview.summary.outputRows, 1_002_001)
        XCTAssertNil(preview.artifact)
        XCTAssertNotNil(preview.blockReason)
    }

    func testEmptyJoinSourcesAndZeroRowPublication() throws {
        let fixture = try AnalysisFixture(rows: [])
        let reference = try right(fixture, rows: [])
        let preview = try join(fixture, right: reference)
        XCTAssertEqual(preview.summary.outputRows, 0)
        XCTAssertEqual(try publish(fixture, preview).rowCount, 0)
    }

    func testUndoRedoAndBranchingRecipesNeverTouchSource() throws {
        let fixture = try AnalysisFixture(rows: [[.text(" A "), .int(1)]])
        var draft = CleaningDraft()
        draft.replace(with: [CleaningStep(operation: .trim)])
        draft.replace(with: draft.steps + [CleaningStep(operation: .lowercase)])
        XCTAssertEqual(try clean(fixture, steps: draft.steps).after.rows[0][1], .text("a"))
        draft.undo()
        XCTAssertTrue(draft.canRedo)
        XCTAssertEqual(try clean(fixture, steps: draft.steps).after.rows[0][1], .text("A"))
        draft.redo()
        XCTAssertEqual(draft.steps.count, 2)
        draft.undo()
        draft.replace(with: draft.steps + [CleaningStep(operation: .uppercase)])
        XCTAssertFalse(draft.canRedo)
        XCTAssertEqual(try fixture.db.scalar("SELECT c0 FROM \(fixture.sheet.tableName)"), .text(" A "))
    }

    func testStrictNumberFormatsPrecisionOverflowAndInvalidText() {
        XCTAssertEqual(CleanValueRules.number(.text("1,234.56"), convention: .dotDecimal), .double(1234.56))
        XCTAssertEqual(CleanValueRules.number(.text("1.234,56"), convention: .commaDecimal), .double(1234.56))
        XCTAssertEqual(CleanValueRules.number(.text("۱٬۲۳۴٫۵۶"), convention: .arabic), .double(1234.56))
        XCTAssertEqual(CleanValueRules.number(.text("9223372036854775807"), convention: .dotDecimal), .int(Int64.max))
        XCTAssertEqual(CleanValueRules.number(.text("1.25e2"), convention: .dotDecimal), .double(125))
        for text in ["1,23", "1.234,56", "12,34,567", "1 234", "NaN", "1e999", "oops", "9223372036854775808", "1.234567890123456"] {
            XCTAssertNil(CleanValueRules.number(.text(text), convention: .dotDecimal), text)
        }
    }

    func testStrictDatesDoNotGuessAmbiguityOrInvalidDays() {
        let functions = PreparationFunctions()
        XCTAssertEqual(functions.date(.text("03/04/2024"), format: .dayFirst), .text("2024-04-03"))
        XCTAssertEqual(functions.date(.text("03/04/2024"), format: .monthFirst), .text("2024-03-04"))
        XCTAssertEqual(functions.date(.text("٢٠٢٤-٠٢-٢٩"), format: .iso), .text("2024-02-29"))
        XCTAssertNil(functions.date(.text("2023-02-29"), format: .iso))
        XCTAssertNil(functions.date(.text("31/04/2024"), format: .dayFirst))
        XCTAssertNil(functions.date(.text("3/4/2024"), format: .dayFirst))
        XCTAssertNil(functions.date(.int(45000), format: .iso))
    }

    func testInvalidConversionsAreCountedRetainedAndRequireApproval() throws {
        let fixture = try AnalysisFixture(rows: [[.text("A"), .text("1,234.50")], [.text("B"), .text("oops")], [.text("C"), .text(" ")]])
        let preview = try clean(fixture, steps: [CleaningStep(operation: .parseNumber, column: 1)])
        XCTAssertEqual(preview.summary.cleaning[0].invalid, 1)
        XCTAssertEqual(preview.summary.cleaning[0].changed, 2)
        XCTAssertEqual(preview.after.rows.map { $0[2] }, [.double(1234.5), .text("oops"), .null])
        XCTAssertEqual(preview.rejected?.rows.count, 1)
        XCTAssertEqual(preview.artifact?.columns[1].kind, .text)
        XCTAssertThrowsError(try publish(fixture, preview))
        XCTAssertEqual(try publish(fixture, preview, invalid: true).rowCount, 3)
    }

    func testCleaningDropDedupAndPublicationCompactRowIDs() throws {
        let fixture = try AnalysisFixture(rows: [[.text(" "), .int(0)], [.text(" A "), .int(1)], [.text("A"), .int(1)], [.text("B"), .int(2)]])
        let preview = try clean(fixture, steps: [CleaningStep(operation: .dropMissing), CleaningStep(operation: .trim), CleaningStep(operation: .removeDuplicates)])
        XCTAssertEqual(preview.summary.cleaning.map(\.removed), [1, 0, 1])
        XCTAssertEqual(preview.after.rows.map { $0[0] }, [.int(2), .int(4)])
        let result = try publish(fixture, preview)
        XCTAssertEqual(try fixture.db.query("SELECT rowid FROM \(result.tableName)"), [[.int(1)], [.int(2)]])
    }

    func testFillLiteralPreservesLeadingZeroesAndEmbeddedNUL() throws {
        let fixture = try AnalysisFixture(rows: [[.null, .int(1)], [.text("a\0b"), .int(2)], [.text("001"), .int(3)]])
        let preview = try clean(fixture, steps: [CleaningStep(operation: .fillMissing, value: "0007")])
        let result = try publish(fixture, preview)
        XCTAssertEqual(try fixture.db.query("SELECT c0,typeof(c0) FROM \(result.tableName)"),
                       [[.text("0007"), .text("text")], [.text("a\0b"), .text("text")], [.text("001"), .text("text")]])
    }

    func testTextOperationsDoNotConvertNumericCells() throws {
        let fixture = try AnalysisFixture(rows: [[.text("١۲ A"), .int(123)]])
        let preview = try clean(fixture, steps: [CleaningStep(operation: .normalizeDigits),
            CleaningStep(operation: .replaceText, value: "A", replacement: "b"), CleaningStep(operation: .lowercase, column: 1)])
        XCTAssertEqual(preview.after.rows[0][1], .text("12 b"))
        XCTAssertEqual(preview.after.rows[0][2], .int(123))
    }

    func testProvenanceRoundTripAndRebuildCreatesIndependentCopies() throws {
        let fixture = try AnalysisFixture(rows: [[.text(" A "), .int(1)]])
        let first = try publish(fixture, clean(fixture, steps: [CleaningStep(operation: .trim)]))
        let record = try XCTUnwrap(fixture.workspace.preparation(sheetID: first.id))
        var recipe = try XCTUnwrap(record.recipe)
        if case .clean(var saved) = recipe.operation { saved.steps = []; recipe.operation = .clean(saved) }
        let second = try publish(fixture, PreparationEngine.prepare(recipe, workspacePath: fixture.db.path))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try fixture.db.scalar("SELECT c0 FROM \(first.tableName)"), .text("A"))
        XCTAssertEqual(try fixture.db.scalar("SELECT c0 FROM \(second.tableName)"), .text(" A "))
        XCTAssertTrue(try fixture.workspace.loadSheets(workbookID: first.workbookID)[0].isDerived)
    }

    func testSourceDeletionKeepsOutputAndHistoryButPreventsRebuild() throws {
        let fixture = try AnalysisFixture()
        let preview = try clean(fixture, steps: [])
        let result = try publish(fixture, preview)
        try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(result.tableName)"), .int(3))
        XCTAssertNotNil(try fixture.workspace.preparation(sheetID: result.id)?.recipe)
        XCTAssertThrowsError(try PreparationEngine.prepare(preview.recipe, workspacePath: fixture.db.path))
        try fixture.workspace.deleteSheet(result.id, workbookID: result.workbookID)
        XCTAssertNil(try fixture.workspace.preparation(sheetID: result.id))
    }

    func testDeletingOrChangingSourceAfterPreviewRefusesPublication() throws {
        let fixture = try AnalysisFixture()
        let preview = try clean(fixture, steps: [])
        try fixture.db.run("UPDATE meta_columns SET name='changed' WHERE sheet_id=?", [.int(fixture.sheet.id)])
        XCTAssertThrowsError(try publish(fixture, preview))
        XCTAssertEqual(try fixture.workspace.loadWorkbooks().count, 1)
        try fixture.workspace.deleteSheet(fixture.sheet.id, workbookID: fixture.sheet.workbookID)
        XCTAssertThrowsError(try publish(fixture, preview))
    }

    func testPublicationRollsBackDDLMetadataAndRowsOnFailure() throws {
        let fixture = try AnalysisFixture()
        let preview = try clean(fixture, steps: [])
        try fixture.db.exec("CREATE TRIGGER reject_preparation BEFORE INSERT ON meta_preparations BEGIN SELECT RAISE(ABORT,'test failure'); END;")
        XCTAssertThrowsError(try publish(fixture, preview))
        XCTAssertEqual(try fixture.workspace.loadWorkbooks().count, 1)
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_sheets"), .int(1))
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'data_*'"), .int(1))
    }

    func testCancellationAndTimeoutAreIsolatedFromSource() throws {
        let fixture = try AnalysisFixture()
        let token = QueryCancellation(); token.cancel()
        let recipe = PreparationRecipe(operation: .clean(CleaningRecipe(source: PreparationSource(fixture.sheet), steps: [])))
        XCTAssertThrowsError(try PreparationEngine.prepare(recipe, workspacePath: fixture.db.path, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        let preview = try clean(fixture, steps: [])
        XCTAssertThrowsError(try PreparationEngine.publish(preview, name: "No", workspacePath: fixture.db.path,
            approveDuplicates: false, approveInvalid: false, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try PreparationBudget(cancellation: QueryCancellation(), seconds: -1).check())
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM meta_sheets"), .int(1))
    }

    func testProgressHandlerInterruptsLongSQLAndConnectionRecovers() throws {
        let fixture = try AnalysisFixture()
        let db = try Database(path: fixture.directory.appendingPathComponent("worker.sqlite").path)
        let budget = PreparationBudget(cancellation: QueryCancellation(), seconds: 0.02)
        XCTAssertThrowsError(try db.withPreparationBudget(budget) {
            try db.scalar("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT SUM(x) FROM n")
        })
        XCTAssertEqual(try db.scalar("SELECT 42"), .int(42))
    }

    func testSourceAttachmentIsReadOnlyAndAIHasNoPreparationFunctions() throws {
        let fixture = try AnalysisFixture()
        let worker = try Database(path: fixture.directory.appendingPathComponent("worker.sqlite").path)
        try worker.run("ATTACH DATABASE ? AS source", [.text(PreparationEngine.readOnlyURI(fixture.db.path))])
        XCTAssertThrowsError(try worker.run("DELETE FROM source.\(fixture.sheet.tableName)"))
        let reader = try fixture.reader()
        XCTAssertThrowsError(try reader.readResult("SELECT sx_clean(c0,'trim','','') FROM data"))
        XCTAssertThrowsError(try reader.configurePreparation())
    }

    func testPreviewIsBoundedAndRecipeValidationRejectsUnsafeShapes() throws {
        let fixture = try AnalysisFixture(rows: (0..<45).map { [.text("ID \($0)"), .int(Int64($0))] })
        let preview = try clean(fixture, steps: [])
        XCTAssertEqual(preview.after.rows.count, 30)
        XCTAssertTrue(preview.after.truncated)
        XCTAssertEqual(preview.summary.outputRows, 45)
        var recipe = preview.recipe; recipe.version = 99
        XCTAssertThrowsError(try recipe.validate())
        XCTAssertThrowsError(try clean(fixture, steps: [CleaningStep(operation: .trim, column: 99)]))
        XCTAssertThrowsError(try clean(fixture, steps: [CleaningStep(operation: .replaceText)]))
        XCTAssertThrowsError(try clean(fixture, steps: (0..<21).map { _ in CleaningStep(operation: .trim) }))
    }
}
