import Foundation
import CoreFoundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case groq, gemini, cerebras, mistral, openRouter, githubModels, openAI, custom

    var id: String { rawValue }

    var display: String {
        switch self {
        case .groq: return "Groq"
        case .gemini: return "Google Gemini"
        case .cerebras: return "Cerebras"
        case .mistral: return "Mistral AI"
        case .openRouter: return "OpenRouter"
        case .githubModels: return "GitHub Models"
        case .openAI: return "OpenAI"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String {
        switch self {
        case .groq: return "llama-3.3-70b-versatile"
        case .gemini: return "gemini-2.5-flash"
        case .cerebras: return "llama-3.3-70b"
        case .mistral: return "mistral-small-latest"
        case .openRouter: return "meta-llama/llama-3.3-70b-instruct:free"
        case .githubModels: return "openai/gpt-4o-mini"
        case .openAI: return "gpt-4o-mini"
        case .custom: return "gpt-4o-mini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .githubModels: return "https://models.github.ai/inference"
        case .openAI: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var keychainKey: String { "apikey_\(rawValue)" }
}

enum AIError: LocalizedError {
    case noKey
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key configured. Add one in Settings."
        case .badResponse(let s): return "Unexpected AI response: \(s)"
        case .http(let code, let body): return "AI request failed (\(code)): \(body.prefix(300))"
        }
    }
}

struct AIConfig {
    var provider: AIProvider
    var model: String
    var baseURL: String
    var apiKey: String
}

/// Talks to OpenAI-compatible and Gemini endpoints. Planning uses schema only; narration uses the caller-provided report/result context.
final class AIClient {
    let config: AIConfig

    private let requestTimeout: TimeInterval
    private let session: URLSession

    init(config: AIConfig, requestTimeout: TimeInterval = 120, session: URLSession = .shared) {
        self.config = config
        self.requestTimeout = requestTimeout
        self.session = session
    }

    // MARK: Public entry points

    /// Converts a natural-language command into a structured plan using the sheet schema.
    func plan(command: String, sheet: SheetInfo) async throws -> CommandPlan {
        let schema = AIClient.schemaDescription(sheet: sheet)
        let system = """
        You translate user requests about a single spreadsheet table into a strict JSON plan.
        Output ONLY minified JSON, no markdown, no commentary.
        Schema of the JSON:
        {"kind":"filterRows|aggregate|topN|summary|duplicates|chart|sql",
         "explanation":"one short sentence",
         "limit":<int>,
         "groupBy":[<columnIndex>],
         "aggregations":[{"function":"count|countDistinct|sum|avg|min|max|median|stdev","columnIndex":<int|null>}],
         "sortDescending":<bool>,
         "filters":[{"columnIndex":<int>,"op":"equals|notEquals|contains|notContains|startsWith|endsWith|greaterThan|greaterOrEqual|lessThan|lessOrEqual|between|isEmpty|notEmpty|inList","value":"","value2":""}],
         "join":"and|or",
         "sorts":[{"columnIndex":<int>,"ascending":<bool>}],
         "search":"",
         "sql":"SELECT ... FROM data ..."}
        Use "sql" only when the request cannot be expressed with the other fields; the table is named data.
        columnIndex values MUST come from the provided schema. Answer in the user's language for "explanation".
        """
        let user = "SHEET SCHEMA:\n\(schema)\n\nUSER REQUEST:\n\(command)"
        let raw = try await complete(system: system, user: user, jsonMode: true)
        return try AIClient.decodePlan(raw, sheet: sheet, fallbackCommand: command)
    }

    /// Writes a narrative report (markdown) from computed statistics.
    func narrate(reportContext: String, language: String) async throws -> String {
        let system = """
        You are a data analyst. Write a concise, well-structured markdown report from the supplied statistics.
        Use headings, bullet points and bold numbers. Highlight anomalies, concentrations, outliers and 3-5 actionable insights.
        Never invent numbers that are not in the input. Write in \(language == "ar" ? "Arabic" : "English").
        """
        return try await complete(system: system, user: reportContext, jsonMode: false)
    }

    func ask(question: String, context: String, language: String) async throws -> String {
        let system = "You answer questions about a spreadsheet using ONLY the provided computed context. " +
                     "Be concise and quantitative. Write in \(language == "ar" ? "Arabic" : "English"). " +
                     "If the context is insufficient, say what extra query is needed."
        return try await complete(system: system, user: "CONTEXT:\n\(context)\n\nQUESTION:\n\(question)", jsonMode: false)
    }

    // MARK: Transport

    func complete(system: String, user: String, jsonMode: Bool) async throws -> String {
        try Task.checkCancellation()
        guard !config.apiKey.isEmpty || config.provider == .custom else { throw AIError.noKey }
        switch config.provider {
        case .gemini: return try await callGemini(system: system, user: user, jsonMode: jsonMode)
        default: return try await callOpenAICompatible(system: system, user: user, jsonMode: jsonMode)
        }
    }

    private func callOpenAICompatible(system: String, user: String, jsonMode: Bool) async throws -> String {
        guard let base = AIEndpoint.baseURL(config.baseURL.isEmpty ? config.provider.defaultBaseURL : config.baseURL) else {
            throw AIError.badResponse("ai.invalidURL".loc)
        }
        let url = base.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if config.provider == .openRouter {
            req.setValue("https://sheetx.app", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("SheetX", forHTTPHeaderField: "X-Title")
        }
        var body: [String: Any] = [
            "model": config.model.isEmpty ? config.provider.defaultModel : config.model,
            "temperature": jsonMode ? 0 : 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if jsonMode, config.provider != .githubModels, config.provider != .cerebras {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        return content
    }

    private func callGemini(system: String, user: String, jsonMode: Bool) async throws -> String {
        guard let base = AIEndpoint.baseURL(config.baseURL.isEmpty ? config.provider.defaultBaseURL : config.baseURL) else {
            throw AIError.badResponse("ai.invalidURL".loc)
        }
        let model = config.model.isEmpty ? config.provider.defaultModel : config.model
        let url = base.appendingPathComponent("models/\(model):generateContent")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        var generation: [String: Any] = ["temperature": jsonMode ? 0 : 0.3]
        if jsonMode { generation["response_mime_type"] = "application/json" }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generation
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIError.badResponse(String(decoding: data, as: UTF8.self).prefix(200).description)
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: Helpers

    static func schemaDescription(sheet: SheetInfo) -> String {
        var lines: [String] = ["table: data", "rows: \(sheet.rowCount)", "columns:"]
        for c in sheet.columns {
            lines.append("  [\(c.index)] \"\(c.name)\" (\(c.kind.rawValue)) sql=c\(c.index)")
        }
        return lines.joined(separator: "\n")
    }

    static func decodePlan(_ raw: String, sheet: SheetInfo, fallbackCommand: String) throws -> CommandPlan {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse(raw.prefix(200).description)
        }

        func array(_ key: String) throws -> [Any] {
            guard let value = obj[key] else { return [] }
            guard let values = value as? [Any] else { throw AnalysisError.invalidPlan }
            return values
        }
        func integer(_ value: Any?) throws -> Int {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = value as? Int else { throw AnalysisError.invalidPlan }
            return integer
        }
        func column(_ value: Any?, required: Bool = true) throws -> Int? {
            if !required && (value == nil || value is NSNull) { return nil }
            let index = try integer(value)
            guard sheet.columns.contains(where: { $0.index == index }) else {
                throw AnalysisError.invalidPlan
            }
            return index
        }
        func boolean(_ value: Any?, fallback: Bool) throws -> Bool {
            guard let value else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw AnalysisError.invalidPlan
            }
            return number.boolValue
        }
        guard let kind = obj["kind"] as? String, let parsedKind = CommandPlan.Kind(rawValue: kind) else {
            throw AnalysisError.invalidPlan
        }
        var plan = CommandPlan()
        plan.kind = parsedKind
        plan.explanation = (obj["explanation"] as? String) ?? fallbackCommand
        plan.sql = (obj["sql"] as? String) ?? ""
        if let limit = obj["limit"] {
            let value = try integer(limit)
            guard value > 0 else { throw AnalysisError.invalidPlan }
            plan.analysis.limit = min(value, 5000)
        }
        plan.analysis.sortDescending = try boolean(obj["sortDescending"], fallback: true)
        plan.analysis.groupBy = try array("groupBy").map { try column($0)! }
        if let search = obj["search"] {
            guard let value = search as? String else { throw AnalysisError.invalidPlan }
            plan.analysis.query.search = value
        }
        if let join = obj["join"] {
            guard let value = join as? String, let parsed = FilterJoin(rawValue: value) else {
                throw AnalysisError.invalidPlan
            }
            plan.analysis.query.join = parsed
        }
        plan.analysis.aggregations = try array("aggregations").map { value in
            guard let item = value as? [String: Any], let name = item["function"] as? String,
                  let function = AggFunction(rawValue: name) else { throw AnalysisError.invalidPlan }
            return Aggregation(function: function,
                               columnIndex: try column(item["columnIndex"], required: function.needsColumn))
        }
        plan.analysis.query.filters = try array("filters").map { value in
            guard let item = value as? [String: Any], let name = item["op"] as? String,
                  let op = FilterOperator(rawValue: name),
                  !op.needsValue || item["value"] != nil else { throw AnalysisError.invalidPlan }
            for key in (op.needsSecondValue ? ["value", "value2"] : (op.needsValue ? ["value"] : [])) {
                let value = item[key]
                guard value is String || value is NSNumber else { throw AnalysisError.invalidPlan }
            }
            return FilterCondition(columnIndex: try column(item["columnIndex"])!, op: op,
                                   value: stringify(item["value"]), value2: stringify(item["value2"]))
        }
        plan.analysis.query.sorts = try array("sorts").map { value in
            guard let item = value as? [String: Any] else { throw AnalysisError.invalidPlan }
            return SortSpec(columnIndex: try column(item["columnIndex"])!,
                            ascending: try boolean(item["ascending"], fallback: true))
        }
        try plan.validate(for: sheet)
        return plan
    }

    private static func stringify(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return DBValue.double(n.doubleValue).stringValue
        default: return ""
        }
    }
}
