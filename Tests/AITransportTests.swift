import XCTest
@testable import SheetX

private final class StubAIProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class AITransportTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAIProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubAIProtocol.handler = nil
        super.tearDown()
    }

    func testKeylessCustomServerAndShortConnectionTestTimeout() async throws {
        StubAIProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.timeoutInterval, 20)
            return (200, Data(#"{"choices":[{"message":{"content":"ready"}}]}"#.utf8))
        }
        let config = AIConfig(provider: .custom, model: "local-model", baseURL: "http://local.test/v1/", apiKey: "")
        let client = AIClient(config: config, requestTimeout: 20, session: session)
        let result = try await client.complete(system: "check", user: "ping", jsonMode: false)
        XCTAssertEqual(result, "ready")
    }

    func testModelFetchUsesHeaderRatherThanPuttingGeminiKeyInURL() async throws {
        StubAIProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "private-key")
            XCTAssertFalse(request.url!.absoluteString.contains("private-key"))
            return (200, Data(#"{"models":[]}"#.utf8))
        }
        let result = try await AIModelDirectory.fetch(provider: .gemini, baseURL: "", apiKey: "private-key", session: session)
        XCTAssertTrue(result.isEmpty)
    }

    func testHTTPErrorIsReportedInsteadOfReplacingCatalogue() async {
        StubAIProtocol.handler = { _ in (429, Data("rate limited".utf8)) }
        do {
            _ = try await AIModelDirectory.fetch(provider: .groq, baseURL: "", apiKey: "key", session: session)
            XCTFail("Expected a rate limit error")
        } catch AIError.http(let code, _) {
            XCTAssertEqual(code, 429)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInvalidCustomEndpointDoesNotSendRequest() async {
        StubAIProtocol.handler = { _ in
            XCTFail("An invalid endpoint must not reach transport")
            return (200, Data())
        }
        do {
            _ = try await AIModelDirectory.fetch(provider: .custom, baseURL: "/v1", apiKey: "", session: session)
            XCTFail("Expected an invalid URL error")
        } catch {}
    }

    func testCancellationIsNotReportedAsSuccessfulFetch() async {
        StubAIProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await AIModelDirectory.fetch(provider: .groq, baseURL: "", apiKey: "key", session: session)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }
}
