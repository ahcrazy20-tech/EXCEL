import XCTest
@testable import SheetX

final class AnalysisSafetyTests: XCTestCase {
    func testSQLAliasAndStringLiteralsAreNotRewritten() throws {
        let fixture = try AnalysisFixture()
        let engine = QueryEngine(db: fixture.db, sheet: fixture.sheet)
        let result = try engine.runSQL("SELECT 'FROM data; DROP TABLE x' AS label,c1 FROM data WHERE c0='A'; -- trailing comment")
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0][0], .text("FROM data; DROP TABLE x"))
        XCTAssertEqual(result.rows[0][1], .int(10))
    }

    func testWritesMetadataOtherSheetsAndDangerousFunctionsAreDenied() throws {
        let fixture = try AnalysisFixture()
        try fixture.db.exec("CREATE TABLE private_data(secret TEXT); INSERT INTO private_data VALUES('secret');")
        let reader = try fixture.reader()
        for sql in ["DELETE\nFROM data", "UPDATE \(fixture.sheet.tableName) SET c0='changed'",
                    "DROP TABLE \(fixture.sheet.tableName)", "CREATE TEMP TABLE t(x)",
                    "ATTACH DATABASE ':memory:' AS other", "PRAGMA user_version=99", "BEGIN",
                    "SELECT * FROM sqlite_master", "SELECT * FROM meta_saved_queries", "SELECT * FROM private_data",
                    "SELECT * FROM pragma_table_info('data')", "SELECT load_extension('anything')",
                    "SELECT randomblob(1000000000)"] {
            XCTAssertThrowsError(try reader.readResult(sql), sql)
        }
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testSecondStatementIsRejectedBeforeExecution() throws {
        let fixture = try AnalysisFixture()
        let reader = try fixture.reader()
        XCTAssertThrowsError(try reader.readResult("SELECT 1; SELECT 2"))
        XCTAssertThrowsError(try reader.readResult("SELECT 1; DELETE FROM \(fixture.sheet.tableName)"))
        XCTAssertEqual(try reader.readResult("SELECT ';' AS semicolon;").rows[0][0], .text(";"))
    }

    func testPreviewCapsRowsAndInternalQueriesThrowInsteadOfSilentlyTruncating() throws {
        let fixture = try AnalysisFixture()
        let reader = try fixture.reader(maxRows: 2)
        let result = try reader.readResult("SELECT c1 FROM data ORDER BY rowid")
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertTrue(result.truncated)
        XCTAssertThrowsError(try reader.query("SELECT c1 FROM data"))
        XCTAssertFalse(try reader.readResult("SELECT c1 FROM data LIMIT 2").truncated)
    }

    func testResultByteLimit() throws {
        let fixture = try AnalysisFixture(rows: (0..<10).map { _ in [.text(String(repeating: "x", count: 100)), .int(1)] })
        let reader = try fixture.reader(maxBytes: 300)
        let result = try reader.readResult("SELECT c0 FROM data")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.rows.count, 2)
    }

    func testStepErrorsAreNotReturnedAsPartialSuccess() throws {
        let fixture = try AnalysisFixture()
        XCTAssertThrowsError(try fixture.db.query("""
            SELECT CASE WHEN rowid=2 THEN abs(-9223372036854775808) ELSE 1 END
            FROM \(fixture.sheet.tableName) ORDER BY rowid
            """))
    }

    func testExpensiveRecursiveQueryHonorsTimeBudget() throws {
        let fixture = try AnalysisFixture()
        let reader = try fixture.reader(timeout: 0.05)
        XCTAssertThrowsError(try reader.query(Self.expensiveSQL)) { error in
            guard case AnalysisError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationDoesNotInterruptTheWorkspaceConnection() throws {
        let fixture = try AnalysisFixture()
        let cancellation = QueryCancellation()
        let reader = try fixture.reader(cancellation: cancellation)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { cancellation.cancel() }
        XCTAssertThrowsError(try reader.query(Self.expensiveSQL)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    func testCancelledParentStopsAnalysisWorker() async throws {
        let fixture = try AnalysisFixture()
        let task = Task {
            try await AnalysisRunner.read(path: fixture.db.path, sheet: fixture.sheet) {
                try $0.db.query(Self.expensiveSQL)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try fixture.db.scalar("SELECT COUNT(*) FROM \(fixture.sheet.tableName)"), .int(3))
    }

    private static let expensiveSQL = """
        WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<100000000)
        SELECT SUM(n) FROM numbers
        """
}
