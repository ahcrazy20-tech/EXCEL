import Foundation

/// Everything the UI needs to know about an AI provider: free tier, where to get a key, endpoints.
extension AIProvider {
    /// Providers listed in the order shown in Settings (free ones first).
    static var ordered: [AIProvider] {
        [.groq, .gemini, .cerebras, .mistral, .openRouter, .githubModels, .openAI, .custom]
    }

    var isFree: Bool {
        switch self {
        case .groq, .gemini, .cerebras, .mistral, .openRouter, .githubModels: return true
        case .openAI, .custom: return false
        }
    }

    /// Short description of the free allowance (verified August 2026).
    var freeQuotaEN: String {
        switch self {
        case .groq: return "Free, no credit card • ~30 req/min, up to 14,400 req/day • very fast (LPU)"
        case .gemini: return "Free tier, no credit card • Gemini Flash models • 1M-token context"
        case .cerebras: return "Free, no credit card • ~1M tokens/day • very fast"
        case .mistral: return "Free mode on by default • ~1B tokens/month • low req/sec"
        case .openRouter: return "Free models (ids ending in :free) • ~20 req/min, 50 req/day"
        case .githubModels: return "Free with a GitHub token • ~15 req/min, 50–150 req/day • GPT/Llama/Phi"
        case .openAI: return "Paid (pay as you go)"
        case .custom: return "Any OpenAI-compatible endpoint (self-hosted, LM Studio, Ollama, proxy…)"
        }
    }

    var freeQuotaAR: String {
        switch self {
        case .groq: return "مجاني بدون بطاقة • حوالي 30 طلب/دقيقة وحتى 14400 طلب/يوم • سريع جدًا"
        case .gemini: return "باقة مجانية بدون بطاقة • موديلات Flash • سياق مليون رمز"
        case .cerebras: return "مجاني بدون بطاقة • حوالي مليون رمز يوميًا • سريع جدًا"
        case .mistral: return "الوضع المجاني مفعّل افتراضيًا • حتى مليار رمز شهريًا • عدد طلبات محدود بالثانية"
        case .openRouter: return "موديلات مجانية (تنتهي بـ :free) • حوالي 20 طلب/دقيقة و50 طلب/يوم"
        case .githubModels: return "مجاني بتوكن GitHub • حوالي 15 طلب/دقيقة و50–150 طلب/يوم"
        case .openAI: return "مدفوع (بالاستهلاك)"
        case .custom: return "أي واجهة متوافقة مع OpenAI (سيرفرك، LM Studio، Ollama، بروكسي…)"
        }
    }

    var quotaText: String { L10n.language == .ar ? freeQuotaAR : freeQuotaEN }

    /// Where the user creates a key.
    var keyPageURL: URL? {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .cerebras: return URL(string: "https://cloud.cerebras.ai/platform")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .githubModels: return URL(string: "https://github.com/settings/personal-access-tokens")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .custom: return nil
        }
    }

    /// Suggested models (used when the live model list cannot be fetched).
    var suggestedModels: [String] {
        switch self {
        case .groq:
            return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b",
                    "openai/gpt-oss-20b", "moonshotai/kimi-k2-instruct", "qwen/qwen3-32b"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash", "gemini-2.5-pro"]
        case .cerebras:
            return ["llama-3.3-70b", "llama3.1-8b", "qwen-3-32b", "gpt-oss-120b"]
        case .mistral:
            return ["mistral-small-latest", "mistral-medium-latest", "open-mistral-nemo", "codestral-latest"]
        case .openRouter:
            return ["meta-llama/llama-3.3-70b-instruct:free", "deepseek/deepseek-chat-v3-0324:free",
                    "google/gemma-3-27b-it:free", "qwen/qwen3-235b-a22b:free", "openai/gpt-oss-120b:free"]
        case .githubModels:
            return ["openai/gpt-4o-mini", "openai/gpt-4.1-mini", "meta/Llama-3.3-70B-Instruct", "microsoft/Phi-4"]
        case .openAI:
            return ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4o"]
        case .custom:
            return []
        }
    }

    var usesGeminiProtocol: Bool { self == .gemini }

    /// Endpoint that lists the models available to this key.
    func modelsURL(baseURL: String, apiKey: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = AIEndpoint.baseURL(base.isEmpty ? defaultBaseURL : base) else { return nil }
        if self == .githubModels {
            return URL(string: "https://models.github.ai/catalog/models")
        }
        let url = root.appendingPathComponent("models")
        if self == .gemini {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            return parts?.url
        }
        return url
    }
}

struct AIModelOption: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isFree: Bool
}

/// Fetches the live model catalogue for a provider so the user can pick a working (free) model.
enum AIModelDirectory {
    static func fetch(provider: AIProvider, baseURL: String, apiKey: String,
                      session: URLSession = .shared) async throws -> [AIModelOption] {
        guard let url = provider.modelsURL(baseURL: baseURL, apiKey: apiKey) else {
            throw AIError.badResponse("ai.invalidURL".loc)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue(provider == .gemini ? key : "Bearer \(key)",
                         forHTTPHeaderField: provider == .gemini ? "x-goog-api-key" : "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.http(code, String(decoding: data.prefix(2000), as: UTF8.self))
        }
        return try parse(data, provider: provider)
    }

    /// Pure parsing, independently testable with provider fixtures. Duplicate identifiers
    /// from compatible APIs must not reach SwiftUI's ForEach diffing.
    static func parse(_ data: Data, provider: AIProvider) throws -> [AIModelOption] {
        let payload = try JSONSerialization.jsonObject(with: data)
        let json = payload as? [String: Any]
        let items: [[String: Any]]
        if provider == .githubModels, let array = payload as? [[String: Any]] {
            items = array
        } else if let array = json?[provider == .gemini ? "models" : "data"] as? [[String: Any]] {
            items = array
        } else {
            throw AIError.badResponse("model list")
        }

        var options: [AIModelOption] = []
        for item in items {
            if provider == .gemini {
                guard let full = item["name"] as? String,
                      let methods = item["supportedGenerationMethods"] as? [String],
                      methods.contains("generateContent") else { continue }
                let name = full.hasPrefix("models/") ? String(full.dropFirst(7)) : full
                options.append(AIModelOption(name: name, isFree: name.contains("flash") || name.contains("lite")))
            } else {
                guard let name = (item["id"] as? String)
                        ?? (provider == .githubModels ? item["name"] as? String : nil) else { continue }
                var free = provider.isFree
                if provider == .openRouter {
                    free = name.hasSuffix(":free")
                    if let pricing = item["pricing"] as? [String: Any] {
                        // A zero input price alone doesn't mean output tokens are free.
                        func isZero(_ value: Any?) -> Bool {
                            if let text = value as? String { return Double(text) == 0 }
                            if let number = value as? NSNumber { return number.doubleValue == 0 }
                            return false
                        }
                        free = free || (isZero(pricing["prompt"]) && isZero(pricing["completion"]))
                    }
                }
                options.append(AIModelOption(name: name, isFree: free))
            }
        }
        return normalized(options)
    }

    static func normalized(_ models: [AIModelOption]) -> [AIModelOption] {
        var unique: [String: Bool] = [:]
        for model in models {
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // Conflicting metadata should not falsely advertise a free model.
            unique[name] = (unique[name] ?? true) && model.isFree
        }
        return unique.map { AIModelOption(name: $0.key, isFree: $0.value) }
            .sorted { ($0.isFree ? 0 : 1, $0.name) < ($1.isFree ? 0 : 1, $1.name) }
    }

    static func matching(_ models: [AIModelOption], query: String, freeOnly: Bool) -> [AIModelOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter {
            (!freeOnly || $0.isFree) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
}

/// Tries several providers in order so a dead/rate-limited key never blocks the user.
final class AIRouter {
    let configs: [AIConfig]
    private(set) var lastUsedProvider: AIProvider?
    private(set) var lastErrors: [String] = []

    init(configs: [AIConfig]) {
        self.configs = configs.filter { !$0.apiKey.isEmpty || $0.provider == .custom }
    }

    var isEmpty: Bool { configs.isEmpty }

    private func attempt<T>(_ work: (AIClient) async throws -> T) async throws -> T {
        guard !configs.isEmpty else { throw AIError.noKey }
        lastErrors = []
        lastUsedProvider = nil
        var lastError: Error = AIError.noKey
        for config in configs {
            try Task.checkCancellation()
            do {
                let value = try await work(AIClient(config: config))
                lastUsedProvider = config.provider
                return value
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastErrors.append("\(config.provider.display): \(message)")
                lastError = error
                continue
            }
        }
        throw AIRouterError.allFailed(lastErrors, underlying: lastError)
    }

    func plan(command: String, sheet: SheetInfo) async throws -> CommandPlan {
        try await attempt { try await $0.plan(command: command, sheet: sheet) }
    }

    func narrate(reportContext: String, language: String) async throws -> String {
        try await attempt { try await $0.narrate(reportContext: reportContext, language: language) }
    }

    func ask(question: String, context: String, language: String) async throws -> String {
        try await attempt { try await $0.ask(question: question, context: context, language: language) }
    }

    func complete(system: String, user: String, jsonMode: Bool) async throws -> String {
        try await attempt { try await $0.complete(system: system, user: user, jsonMode: jsonMode) }
    }
}

enum AIRouterError: LocalizedError {
    case allFailed([String], underlying: Error)

    var errorDescription: String? {
        switch self {
        case .allFailed(let messages, let underlying):
            if messages.isEmpty {
                return (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
            }
            let head = L10n.language == .ar ? "كل المزوّدين فشلوا:\n" : "All providers failed:\n"
            return head + messages.joined(separator: "\n")
        }
    }
}
