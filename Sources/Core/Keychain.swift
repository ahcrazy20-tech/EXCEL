import Foundation
import Security

/// Async boundary for secure storage; views must only read the in-memory settings cache.
protocol AICredentialStorage {
    func load() async throws -> [AIProvider: String]
    func set(_ value: String, for provider: AIProvider) async throws
}

struct KeychainCredentialStorage: AICredentialStorage {
    // Security framework calls are synchronous IPC. Keep them off the UI thread,
    // including writes, and serialize operations to avoid read/write races.
    private static let queue = DispatchQueue(label: "com.sheetx.credentials", qos: .userInitiated)
    private static let service = "com.sheetx.app.secrets"

    func load() async throws -> [AIProvider: String] {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    var keys: [AIProvider: String] = [:]
                    for provider in AIProvider.allCases {
                        var query = Self.query(for: provider)
                        query[kSecReturnData as String] = true
                        query[kSecMatchLimit as String] = kSecMatchLimitOne
                        var item: CFTypeRef?
                        let status = SecItemCopyMatching(query as CFDictionary, &item)
                        if status == errSecItemNotFound { continue }
                        try Self.check(status)
                        guard let data = item as? Data,
                              let key = String(data: data, encoding: .utf8) else {
                            throw CredentialStorageError(status: errSecDecode)
                        }
                        keys[provider] = key
                    }
                    continuation.resume(returning: keys)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func set(_ value: String, for provider: AIProvider) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    let query = Self.query(for: provider)
                    if value.isEmpty {
                        let status = SecItemDelete(query as CFDictionary)
                        if status != errSecItemNotFound { try Self.check(status) }
                    } else {
                        let attributes = [kSecValueData as String: Data(value.utf8)]
                        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                        if status == errSecItemNotFound {
                            var add = query
                            add.removeValue(forKey: kSecUseAuthenticationUI as String)
                            add[kSecValueData as String] = Data(value.utf8)
                            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                            try Self.check(SecItemAdd(add as CFDictionary, nil))
                        } else {
                            // Never delete an existing key before a replacement succeeds.
                            try Self.check(status)
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func query(for provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.keychainKey,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialStorageError(status: status) }
    }
}

struct CredentialStorageError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
        return "\("ai.keychainError".loc) (\(status)): \(detail)"
    }
}
