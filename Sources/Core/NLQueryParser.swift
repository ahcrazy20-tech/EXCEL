import Foundation

/// The structured result of interpreting a natural-language command.
struct CommandPlan: Codable, Hashable {
    enum Kind: String, Codable {
        case filterRows      // show matching rows
        case aggregate       // group + aggregate
        case topN            // ranking
        case summary         // full profile / report
        case duplicates
        case chart
        case sql
    }

    var kind: Kind = .filterRows
    var analysis = AnalysisSpec()
    var explanation: String = ""
    var sql: String = ""
    var chartColumn: Int?
    var confidence: Double = 0.5
}

/// Offline natural-language interpreter for Arabic + English commands.
/// It maps phrases onto columns, operators, aggregates and limits without any network access.
struct NLQueryParser {
    let sheet: SheetInfo

    private static let arabicDigits: [Character: Character] = [
        "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
        "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
        "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4", "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9"
    ]

    static func normalize(_ input: String) -> String {
        var s = input.lowercased()
        s = String(s.map { arabicDigits[$0] ?? $0 })
        // Arabic letter normalisation
        let map: [Character: Character] = ["أ": "ا", "إ": "ا", "آ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي"]
        s = String(s.map { map[$0] ?? $0 })
        s = s.replacingOccurrences(of: "[\\u064B-\\u065F\\u0670]", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Keyword tables ------------------------------------------------------

    private static let sumWords = ["sum", "total", "مجموع", "اجمالي", "إجمالي", "جمع", "المجموع", "الاجمالي", "اجمع"]
    private static let avgWords = ["average", "avg", "mean", "متوسط", "المتوسط", "معدل", "المعدل"]
    private static let countWords = ["count", "how many", "number of", "عدد", "كم", "احصي", "احصاء", "كام"]
    private static let maxWords = ["max", "maximum", "highest", "largest", "biggest", "اكبر", "أكبر", "اعلي", "أعلى", "الاعلي", "اقصي", "قصوي"]
    private static let minWords = ["min", "minimum", "lowest", "smallest", "اصغر", "أصغر", "اقل", "أقل", "الاقل", "ادني", "أدنى"]
    private static let medianWords = ["median", "الوسيط", "وسيط"]
    private static let distinctWords = ["distinct", "unique", "مميز", "فريد", "مختلف", "بدون تكرار"]
    private static let topWords = ["top", "best", "highest", "افضل", "أفضل", "اعلي", "أعلى", "اكبر", "أكبر", "الاوائل", "ترتيب"]
    private static let bottomWords = ["bottom", "worst", "lowest", "اسوا", "أسوأ", "اقل", "أقل", "ادني", "الاخير"]
    private static let groupWords = ["by", "per", "for each", "group", "حسب", "لكل", "بحسب", "بالنسبه ل", "تجميع", "مجمع"]
    private static let dupWords = ["duplicate", "duplicates", "repeated", "مكرر", "المكرر", "تكرار", "المكرره", "مكرره"]
    private static let summaryWords = ["summary", "summarise", "summarize", "report", "overview", "profile", "describe",
                                       "ملخص", "تلخيص", "تقرير", "نظره عامه", "لخص", "وصف", "احصائيات", "إحصائيات"]
    private static let chartWords = ["chart", "graph", "plot", "رسم", "مخطط", "بياني", "شارت"]
    private static let containsWords = ["contains", "like", "يحتوي", "تحتوي", "فيه", "فيها", "يشمل"]
    private static let equalWords = ["equals", "equal", "is", "=", "يساوي", "تساوي", "هو", "هي"]
    private static let greaterWords = ["greater than", "more than", "over", "above", ">", "اكبر من", "أكبر من", "اكثر من", "أكثر من", "فوق", "يزيد عن", "تزيد عن"]
    private static let lessWords = ["less than", "under", "below", "<", "اقل من", "أقل من", "اصغر من", "تحت", "يقل عن"]
    private static let emptyWords = ["empty", "blank", "missing", "null", "فارغ", "فارغه", "ناقص", "مفقود", "خالي"]

    // ---------------------------------------------------------------------

    func parse(_ input: String) -> CommandPlan {
        let text = NLQueryParser.normalize(input)
        var plan = CommandPlan()
        var confidence = 0.35

        if text.hasPrefix("select ") || text.hasPrefix("with ") {
            plan.kind = .sql
            plan.sql = input
            plan.explanation = "Raw SQL"
            plan.confidence = 0.95
            return plan
        }

        // Number / limit extraction
        let numbers = NLQueryParser.numbers(in: text)
        var limit = 20
        if let m = text.range(of: "(top|first|اول|أول|افضل|أفضل|اعلي|أعلى|اكبر|أكبر|اقل|أقل|اصغر|اسوا)\\s+(\\d+)", options: .regularExpression) {
            let piece = String(text[m])
            if let n = NLQueryParser.numbers(in: piece).last { limit = max(1, Int(n)) }
            confidence += 0.1
        } else if let m = text.range(of: "(\\d+)\\s*(rows|records|صف|صفوف|سجل|سجلات|نتيجه|نتائج)", options: .regularExpression) {
            if let n = NLQueryParser.numbers(in: String(text[m])).first { limit = max(1, Int(n)) }
        }
        plan.analysis.limit = limit

        // Column mentions
        let mentions = matchColumns(in: text)
        if !mentions.isEmpty { confidence += 0.15 }

        // Filters from the text
        let (filters, usedColumns) = extractFilters(text: text, original: input, mentions: mentions, numbers: numbers)
        plan.analysis.query.filters = filters
        if !filters.isEmpty { confidence += 0.15 }

        // Free-text search fallback: quoted phrase
        if let quoted = NLQueryParser.quotedPhrase(in: input), filters.isEmpty {
            plan.analysis.query.search = quoted
            confidence += 0.2
        }

        let has: ([String]) -> Bool = { words in words.contains { text.contains($0) } }

        // Duplicates
        if has(NLQueryParser.dupWords) {
            plan.kind = .duplicates
            plan.analysis.groupBy = mentions.isEmpty ? [bestTextColumn()].compactMap { $0 } : mentions.map { $0.index }
            plan.explanation = "Find duplicated values"
            plan.confidence = min(1, confidence + 0.3)
            return plan
        }

        // Whole-sheet summary
        if has(NLQueryParser.summaryWords) && mentions.isEmpty {
            plan.kind = .summary
            plan.explanation = "Full sheet summary report"
            plan.confidence = min(1, confidence + 0.35)
            return plan
        }

        // Chart
        if has(NLQueryParser.chartWords) {
            plan.kind = .chart
            confidence += 0.2
        }

        // Aggregation function
        var function: AggFunction?
        if has(NLQueryParser.sumWords) { function = .sum }
        else if has(NLQueryParser.avgWords) { function = .avg }
        else if has(NLQueryParser.medianWords) { function = .median }
        else if has(NLQueryParser.distinctWords) && has(NLQueryParser.countWords) { function = .countDistinct }
        else if has(NLQueryParser.countWords) { function = .count }
        else if has(NLQueryParser.maxWords) { function = .max }
        else if has(NLQueryParser.minWords) { function = .min }

        // Grouping: "by <column>" / "حسب <column>" / "لكل <column>"
        var groupColumn: ColumnInfo?
        if let gc = groupColumnMention(text: text, mentions: mentions) {
            groupColumn = gc
            confidence += 0.2
        }

        // The measure column: first numeric mention that is not the group column and not used in a filter
        let numericMention = mentions.first {
            $0.kind == .number && $0.index != groupColumn?.index && !usedColumns.contains($0.index)
        }
        let measureColumn = numericMention ?? mentions.first { $0.index != groupColumn?.index && !usedColumns.contains($0.index) }

        if let function {
            plan.kind = .aggregate
            if let g = groupColumn { plan.analysis.groupBy = [g.index] }
            var agg = Aggregation(function: function, columnIndex: function.needsColumn ? measureColumn?.index : nil)
            if function.needsColumn && agg.columnIndex == nil {
                if let firstNumeric = sheet.columns.first(where: { $0.kind == .number }) {
                    agg.columnIndex = firstNumeric.index
                } else {
                    agg = Aggregation(function: .count, columnIndex: nil)
                }
            }
            plan.analysis.aggregations = [agg]
            plan.analysis.sortDescending = !has(NLQueryParser.bottomWords)
            plan.explanation = describe(plan, groupColumn: groupColumn)
            plan.confidence = min(1, confidence + 0.25)
            if plan.kind == .aggregate && groupColumn == nil && plan.analysis.query.filters.isEmpty
                && plan.analysis.query.search.isEmpty && function == .count {
                plan.explanation = "Total row count"
            }
            return plan
        }

        // Top / bottom N without an explicit function -> ranking rows by a numeric column
        if has(NLQueryParser.topWords) || has(NLQueryParser.bottomWords) {
            let desc = !has(NLQueryParser.bottomWords)
            let sortCol = numericMention ?? sheet.columns.first(where: { $0.kind == .number })
            if let sortCol {
                plan.kind = .topN
                plan.analysis.query.sorts = [SortSpec(columnIndex: sortCol.index, ascending: !desc)]
                plan.analysis.limit = limit
                plan.explanation = "\(desc ? "Top" : "Bottom") \(limit) rows by \(sortCol.name)"
                plan.confidence = min(1, confidence + 0.3)
                return plan
            }
        }

        // Plain search / filter
        plan.kind = .filterRows
        if plan.analysis.query.filters.isEmpty && plan.analysis.query.search.isEmpty {
            // Use the leftover words as a global search term.
            let stop = Set(["show", "find", "get", "list", "rows", "where", "the", "all", "me", "of", "in", "a", "an",
                            "اعرض", "ابحث", "عن", "هات", "اظهر", "الصفوف", "اللي", "التي", "في", "من", "كل", "جيب", "وريني", "عايز", "عاوز"])
            let words = text.split(whereSeparator: { $0 == " " }).map(String.init)
                .filter { !stop.contains($0) && $0.count > 1 && Double($0) == nil }
            if let candidate = words.last, !candidate.isEmpty {
                plan.analysis.query.search = candidate
            }
        }
        plan.analysis.limit = max(limit, 100)
        plan.explanation = plan.analysis.query.search.isEmpty
            ? "Filtered rows"
            : "Rows containing “\(plan.analysis.query.search)”"
        plan.confidence = confidence
        return plan
    }

    // MARK: - helpers

    private func describe(_ plan: CommandPlan, groupColumn: ColumnInfo?) -> String {
        let agg = plan.analysis.aggregations.first
        let fn = agg?.function.display ?? "COUNT"
        let colName = agg?.columnIndex.map { sheet.columns[$0].name } ?? "rows"
        if let g = groupColumn { return "\(fn) of \(colName) grouped by \(g.name)" }
        return "\(fn) of \(colName)"
    }

    private func bestTextColumn() -> Int? {
        sheet.columns.first(where: { $0.kind == .text })?.index ?? sheet.columns.first?.index
    }

    struct Mention {
        let index: Int
        let name: String
        let kind: ColumnKind
        let range: Range<String.Index>
    }

    /// Finds columns referenced by name (longest match first, normalised on both sides).
    func matchColumns(in text: String) -> [Mention] {
        var found: [Mention] = []
        let candidates = sheet.columns
            .map { (col: $0, key: NLQueryParser.normalize($0.name)) }
            .filter { !$0.key.isEmpty }
            .sorted { $0.key.count > $1.key.count }
        var consumed: [Range<String.Index>] = []
        for c in candidates where c.key.count >= 2 {
            guard let r = text.range(of: c.key) else { continue }
            if consumed.contains(where: { $0.overlaps(r) }) { continue }
            consumed.append(r)
            found.append(Mention(index: c.col.index, name: c.col.name, kind: c.col.kind, range: r))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func groupColumnMention(text: String, mentions: [Mention]) -> ColumnInfo? {
        for kw in NLQueryParser.groupWords {
            guard let kwRange = text.range(of: kw) else { continue }
            // First column mentioned after the grouping keyword.
            if let m = mentions.first(where: { $0.range.lowerBound >= kwRange.upperBound }) {
                return sheet.columns.first { $0.index == m.index }
            }
        }
        return nil
    }

    private static func numbers(in text: String) -> [Double] {
        var out: [Double] = []
        let pattern = "-?\\d+(?:[.,]\\d+)?"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = text as NSString
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, let d = Double(ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")) { out.append(d) }
        }
        return out
    }

    static func quotedPhrase(in input: String) -> String? {
        for pair in [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")] {
            if let a = input.range(of: pair.0), let b = input.range(of: pair.1, range: a.upperBound..<input.endIndex) {
                let phrase = String(input[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { return phrase }
            }
        }
        return nil
    }

    /// Builds filters like "where city = jeddah", "أكبر من 1000", "الحاله فارغه".
    private func extractFilters(text: String, original: String, mentions: [Mention], numbers: [Double]) -> ([FilterCondition], Set<Int>) {
        var filters: [FilterCondition] = []
        var used = Set<Int>()

        for m in mentions {
            let after = String(text[m.range.upperBound...])
            let window = String(after.prefix(60))

            func firstNumber() -> Double? { NLQueryParser.numbers(in: window).first }

            if NLQueryParser.greaterWords.contains(where: { window.contains($0) }), let n = firstNumber() {
                filters.append(FilterCondition(columnIndex: m.index, op: .greaterThan, value: NLQueryParser.trim(n)))
                used.insert(m.index); continue
            }
            if NLQueryParser.lessWords.contains(where: { window.contains($0) }), let n = firstNumber() {
                filters.append(FilterCondition(columnIndex: m.index, op: .lessThan, value: NLQueryParser.trim(n)))
                used.insert(m.index); continue
            }
            if window.contains("between") || window.contains("بين") {
                let ns = NLQueryParser.numbers(in: window)
                if ns.count >= 2 {
                    filters.append(FilterCondition(columnIndex: m.index, op: .between,
                                                   value: NLQueryParser.trim(ns[0]), value2: NLQueryParser.trim(ns[1])))
                    used.insert(m.index); continue
                }
            }
            if NLQueryParser.emptyWords.contains(where: { window.contains($0) }) {
                filters.append(FilterCondition(columnIndex: m.index, op: .isEmpty))
                used.insert(m.index); continue
            }
            if NLQueryParser.containsWords.contains(where: { window.contains($0) }) {
                if let phrase = NLQueryParser.quotedPhrase(in: original) ?? NLQueryParser.wordAfterKeyword(window, keywords: NLQueryParser.containsWords) {
                    filters.append(FilterCondition(columnIndex: m.index, op: .contains, value: phrase))
                    used.insert(m.index); continue
                }
            }
            if NLQueryParser.equalWords.contains(where: { window.hasPrefix(" \($0) ") || window.contains(" \($0) ") }) {
                if let phrase = NLQueryParser.quotedPhrase(in: original) ?? NLQueryParser.wordAfterKeyword(window, keywords: NLQueryParser.equalWords) {
                    let op: FilterOperator = m.kind == .number ? .equals : .contains
                    filters.append(FilterCondition(columnIndex: m.index, op: op, value: phrase))
                    used.insert(m.index); continue
                }
            }
        }
        return (filters, used)
    }

    private static func wordAfterKeyword(_ window: String, keywords: [String]) -> String? {
        for k in keywords {
            guard let r = window.range(of: k) else { continue }
            let rest = window[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let word = rest.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init)
            if let word, word.count > 0, Double(word) == nil || k == "=" { return word }
        }
        return nil
    }

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int64(d)) : String(d)
    }

    /// Ready-made example commands offered in the UI.
    static func suggestions(for sheet: SheetInfo, arabic: Bool) -> [String] {
        let numeric = sheet.columns.first(where: { $0.kind == .number })?.name
        let textCol = sheet.columns.first(where: { $0.kind == .text })?.name
        var out: [String] = []
        if arabic {
            out.append("اعمل تقرير ملخص للشيت")
            if let n = numeric, let t = textCol { out.append("مجموع \(n) حسب \(t)") }
            if let n = numeric { out.append("أعلى 10 حسب \(n)") }
            if let t = textCol { out.append("عدد الصفوف حسب \(t)") }
            if let t = textCol { out.append("القيم المكررة في \(t)") }
            if let n = numeric { out.append("الصفوف اللي \(n) أكبر من 1000") }
        } else {
            out.append("Summarize this sheet")
            if let n = numeric, let t = textCol { out.append("Sum of \(n) by \(t)") }
            if let n = numeric { out.append("Top 10 by \(n)") }
            if let t = textCol { out.append("Count rows by \(t)") }
            if let t = textCol { out.append("Find duplicates in \(t)") }
            if let n = numeric { out.append("Rows where \(n) greater than 1000") }
        }
        return out
    }
}
