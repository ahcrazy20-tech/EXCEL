import XCTest
@testable import SheetX

private actor MemoryCredentials: AICredentialStorage {
    private var keys: [AIProvider: String] = [.groq: "stored-key"]
    private(set) var loads = 0
    private var failWrites = false
    private var failLoads = false

    func setFailures(load: Bool = false, write: Bool = false) {
        failLoads = load
        failWrites = write
    }

    func load() async throws -> [AIProvider: String] {
        loads += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        if failLoads { throw URLError(.cannotOpenFile) }
        return keys
    }

    func set(_ value: String, for provider: AIProvider) async throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        keys[provider] = value
    }
}

@MainActor
final class AICredentialTests: XCTestCase {
    func testRenderingNeverReadsSecureStorage() async throws {
        let storage = MemoryCredentials()
        let settings = AppSettings(credentialStorage: storage)
        for _ in 0..<100 {
            _ = settings.hasAI
            _ = settings.configuredProviders
            for provider in AIProvider.allCases { _ = settings.hasKey(provider) }
        }
        let initialLoads = await storage.loads
        XCTAssertEqual(initialLoads, 0)
        try await settings.loadAPIKeys()
        XCTAssertTrue(settings.apiKeysLoaded)
        XCTAssertTrue(settings.hasKey(.groq))
        for _ in 0..<100 { _ = settings.hasKey(.groq) }
        let finalLoads = await storage.loads
        XCTAssertEqual(finalLoads, 1)
    }

    func testConcurrentLoadingSharesOneRequest() async throws {
        let storage = MemoryCredentials()
        let settings = AppSettings(credentialStorage: storage)
        async let first: Void = settings.loadAPIKeys()
        async let second: Void = settings.loadAPIKeys()
        _ = try await (first, second)
        let loads = await storage.loads
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(settings.apiKey(for: .groq), "stored-key")
    }

    func testFailedWritePreservesExistingKey() async throws {
        let storage = MemoryCredentials()
        let settings = AppSettings(credentialStorage: storage)
        try await settings.loadAPIKeys()
        await storage.setFailures(write: true)
        do {
            try await settings.setAPIKey("replacement", for: .groq)
            XCTFail("A failed secure write must be reported")
        } catch {}
        XCTAssertEqual(settings.apiKey(for: .groq), "stored-key")
    }

    func testSaveTrimsAndRemovalUpdatesCache() async throws {
        let settings = AppSettings(credentialStorage: MemoryCredentials())
        try await settings.setAPIKey("  replacement\n", for: .groq)
        XCTAssertEqual(settings.apiKey(for: .groq), "replacement")
        try await settings.setAPIKey("", for: .groq)
        XCTAssertFalse(settings.hasKey(.groq))
        try await settings.loadAPIKeys()
        XCTAssertFalse(settings.hasKey(.groq), "Reload must not restore a stale snapshot")
    }

    func testFailedReadCanBeRetried() async throws {
        let storage = MemoryCredentials()
        let settings = AppSettings(credentialStorage: storage)
        await storage.setFailures(load: true)
        do {
            try await settings.loadAPIKeys()
            XCTFail("Expected a read error")
        } catch {}
        XCTAssertFalse(settings.apiKeysLoaded)
        XCTAssertNotNil(settings.apiKeyLoadError)
        await storage.setFailures()
        try await settings.loadAPIKeys()
        XCTAssertTrue(settings.apiKeysLoaded)
        XCTAssertNil(settings.apiKeyLoadError)
        XCTAssertTrue(settings.hasKey(.groq))
    }
}
