import XCTest
@testable import SheetX

final class DataOverviewTests: XCTestCase {
    func testMissingValuesAndNumbersDoNotTreatInvalidTextAsZero() async throws {
        let fixture = try AnalysisFixture()
        let overview = try await AnalysisRunner.read(path: fixture.db.path, sheet: fixture.sheet) {
            try DataOverview.build(engine: $0, query: QuerySpec())
        }
        XCTAssertEqual(overview.matchingRows, 3)
        XCTAssertEqual(overview.sampledRows, 3)
        XCTAssertFalse(overview.isSampled)
        XCTAssertEqual(overview.missingCells, 2)
        XCTAssertEqual(overview.columns[0].distinct, 1)
        XCTAssertEqual(overview.columns[1].average, 20)
        XCTAssertEqual(overview.columns[1].invalidNumbers, 1)
        XCTAssertEqual(overview.completeness ?? 0, 4.0 / 6.0, accuracy: 0.001)
    }

    func testSamplingIsExplicitAndUsesSourceOrder() async throws {
        let fixture = try AnalysisFixture()
        let result = try await AnalysisRunner.read(path: fixture.db.path, sheet: fixture.sheet) {
            try DataOverview.build(engine: $0, query: QuerySpec(), sampleLimit: 1)
        }
        XCTAssertEqual(result.matchingRows, 3)
        XCTAssertEqual(result.sampledRows, 1)
        XCTAssertTrue(result.isSampled)
        XCTAssertEqual(result.columns[1].average, 10)
    }

    func testOverviewRespectsFiltersAndEmptyResults() async throws {
        let fixture = try AnalysisFixture()
        let query = QuerySpec(filters: [FilterCondition(columnIndex: 0, op: .equals, value: "none")])
        let result = try await AnalysisRunner.read(path: fixture.db.path, sheet: fixture.sheet) {
            try DataOverview.build(engine: $0, query: query)
        }
        XCTAssertEqual(result.matchingRows, 0)
        XCTAssertNil(result.completeness)
        XCTAssertNil(result.columns[1].average)
        XCTAssertEqual(result.missingCells, 0)
    }
}
