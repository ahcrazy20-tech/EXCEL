import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case openAI, gemini, openRouter, custom

    var id: String { rawValue }

    var display: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-1.5-flash"
        case .openRouter: return "openai/gpt-4o-mini"
        case .custom: return "gpt-4o-mini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
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

/// Talks to OpenAI-compatible and Gemini endpoints. Only schema + tiny samples are sent — never the whole file.
final class AIClient {
    let config: AIConfig

    init(config: AIConfig) { self.config = config }

    // MARK: Public entry points

    /// Converts a natural-language command into a structured plan using the sheet schema.
    func plan(command: String, sheet: SheetInfo, sample: ResultTable) async throws -> CommandPlan {
        let schema = AIClient.schemaDescription(sheet: sheet, sample: sample)
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
        guard !config.apiKey.isEmpty else { throw AIError.noKey }
        switch config.provider {
        case .gemini: return try await callGemini(system: system, user: user, jsonMode: jsonMode)
        default: return try await callOpenAICompatible(system: system, user: user, jsonMode: jsonMode)
        }
    }

    private func callOpenAICompatible(system: String, user: String, jsonMode: Bool) async throws -> String {
        var base = config.baseURL.isEmpty ? config.provider.defaultBaseURL : config.baseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.badResponse("bad base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
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
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
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
        var base = config.baseURL.isEmpty ? config.provider.defaultBaseURL : config.baseURL
        if base.hasSuffix("/") { base.removeLast() }
        let model = config.model.isEmpty ? config.provider.defaultModel : config.model
        guard let url = URL(string: "\(base)/models/\(model):generateContent?key=\(config.apiKey)") else {
            throw AIError.badResponse("bad base URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var generation: [String: Any] = ["temperature": jsonMode ? 0 : 0.3]
        if jsonMode { generation["response_mime_type"] = "application/json" }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generation
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
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

    static func schemaDescription(sheet: SheetInfo, sample: ResultTable) -> String {
        var lines: [String] = ["table: data", "rows: \(sheet.rowCount)", "columns:"]
        for c in sheet.columns {
            lines.append("  [\(c.index)] \"\(c.name)\" (\(c.kind.rawValue)) sql=c\(c.index)")
        }
        if !sample.rows.isEmpty {
            lines.append("sample rows (first \(min(5, sample.rows.count))):")
            for r in sample.rows.prefix(5) {
                lines.append("  " + r.map { $0.stringValue.prefix(24).description }.joined(separator: " | "))
            }
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

        var plan = CommandPlan()
        plan.kind = CommandPlan.Kind(rawValue: (obj["kind"] as? String) ?? "filterRows") ?? .filterRows
        plan.explanation = (obj["explanation"] as? String) ?? ""
        plan.sql = (obj["sql"] as? String) ?? ""
        plan.confidence = 0.9

        let maxIndex = sheet.columns.count - 1
        func valid(_ i: Int?) -> Int? {
            guard let i, i >= 0, i <= maxIndex else { return nil }
            return i
        }

        plan.analysis.limit = (obj["limit"] as? Int) ?? 50
        plan.analysis.sortDescending = (obj["sortDescending"] as? Bool) ?? true
        plan.analysis.groupBy = ((obj["groupBy"] as? [Any]) ?? []).compactMap { valid($0 as? Int) }
        plan.analysis.query.search = (obj["search"] as? String) ?? ""
        if let j = obj["join"] as? String, let join = FilterJoin(rawValue: j) { plan.analysis.query.join = join }

        if let aggs = obj["aggregations"] as? [[String: Any]] {
            plan.analysis.aggregations = aggs.compactMap { a in
                guard let f = a["function"] as? String, let fn = AggFunction(rawValue: f) else { return nil }
                return Aggregation(function: fn, columnIndex: valid(a["columnIndex"] as? Int))
            }
        }
        if let filters = obj["filters"] as? [[String: Any]] {
            plan.analysis.query.filters = filters.compactMap { f in
                guard let idx = valid(f["columnIndex"] as? Int) else { return nil }
                let op = FilterOperator(rawValue: (f["op"] as? String) ?? "contains") ?? .contains
                return FilterCondition(columnIndex: idx, op: op,
                                       value: stringify(f["value"]), value2: stringify(f["value2"]))
            }
        }
        if let sorts = obj["sorts"] as? [[String: Any]] {
            plan.analysis.query.sorts = sorts.compactMap { s in
                guard let idx = valid(s["columnIndex"] as? Int) else { return nil }
                return SortSpec(columnIndex: idx, ascending: (s["ascending"] as? Bool) ?? true)
            }
        }
        if plan.kind == .sql && plan.sql.isEmpty { plan.kind = .filterRows }
        if plan.explanation.isEmpty { plan.explanation = fallbackCommand }
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
