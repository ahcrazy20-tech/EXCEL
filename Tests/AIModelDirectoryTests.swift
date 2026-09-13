import XCTest
@testable import SheetX

final class AIModelDirectoryTests: XCTestCase {
    func testCatalogueHasUniqueNonemptyStableIdentifiers() throws {
        let data = Data(#"{"data":[{"id":" z "},{"id":"z"},{"id":""},{"id":"a"},{"name":"no-id"}]}"#.utf8)
        let models = try AIModelDirectory.parse(data, provider: .groq)
        XCTAssertEqual(models.map(\.id), ["a", "z"])
    }

    func testSearchIncludesModelsBeyondFormerFortyRowLimit() {
        let models = (0..<1000).map { AIModelOption(name: "model-\($0)", isFree: $0 % 2 == 0) }
        XCTAssertEqual(AIModelDirectory.matching(models, query: " MODEL-999 ", freeOnly: false).map(\.name), ["model-999"])
        XCTAssertEqual(AIModelDirectory.matching(models, query: "", freeOnly: false).count, 1000)
        XCTAssertEqual(AIModelDirectory.matching(models, query: "", freeOnly: true).count, 500)
        XCTAssertTrue(AIModelDirectory.matching(models, query: "model-999", freeOnly: true).isEmpty)
    }

    func testGeminiOnlyShowsContentGenerationModels() throws {
        let data = Data(#"{"models":[{"name":"models/gemini-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]},{"name":"models/unknown"}]}"#.utf8)
        let models = try AIModelDirectory.parse(data, provider: .gemini)
        XCTAssertEqual(models.map(\.name), ["gemini-flash"])
    }

    func testGitHubBareArray() throws {
        let data = Data(#"[{"id":"openai/gpt-4o-mini"},{"name":"legacy-name"},{"id":"openai/gpt-4o-mini"}]"#.utf8)
        XCTAssertEqual(try AIModelDirectory.parse(data, provider: .githubModels).count, 2)
    }

    func testFreePricingRequiresBothInputAndOutputToBeFree() throws {
        let data = Data(#"{"data":[{"id":"paid-output","pricing":{"prompt":"0","completion":"1"}},{"id":"zero-cost","pricing":{"prompt":"0","completion":"0"}},{"id":"tagged:free"},{"id":"paid"}]}"#.utf8)
        let models = try AIModelDirectory.parse(data, provider: .openRouter)
        XCTAssertEqual(models.filter(\.isFree).map(\.name), ["tagged:free", "zero-cost"])
    }

    func testMalformedShapeIsNotSilentlyTreatedAsEmpty() {
        XCTAssertThrowsError(try AIModelDirectory.parse(Data(#"{"error":"bad key"}"#.utf8), provider: .groq))
        XCTAssertThrowsError(try AIModelDirectory.parse(Data("not json".utf8), provider: .gemini))
    }

    func testEndpointValidationAndSecretFreeGeminiURL() {
        for invalid in ["", "/v1", "localhost:1234", "file:///tmp", "https://", "https://user:secret@host/v1", "https://host/v1?key=secret", "https://host/#part"] {
            XCTAssertNil(AIEndpoint.baseURL(invalid), invalid)
        }
        XCTAssertNotNil(AIEndpoint.baseURL(" http://192.168.1.10:1234/v1/ "))
        let url = AIProvider.gemini.modelsURL(baseURL: "", apiKey: "secret&value")
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.absoluteString.contains("secret"))
        XCTAssertEqual(url?.path, "/v1beta/models")
    }
}

final class AISchemaTests: XCTestCase {
    func testPlanningContextContainsOnlySchemaAndRowCount() {
        let sheet = SheetInfo(id: 1, workbookID: 1, name: "Sales", tableName: "data_1",
                              rowCount: 1000,
                              columns: [ColumnInfo(index: 0, name: "Amount", kind: .number)], index: 0)
        XCTAssertEqual(AIClient.schemaDescription(sheet: sheet),
                       "table: data\nrows: 1000\ncolumns:\n  [0] \"Amount\" (number) sql=c0")
    }
}
