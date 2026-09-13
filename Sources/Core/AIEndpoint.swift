import Foundation

/// Reject relative, credential-bearing and non-HTTP URLs before starting a request.
/// HTTP remains supported for private-network Ollama / LM Studio installations.
enum AIEndpoint {
    static func baseURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }
}
