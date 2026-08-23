import Foundation

/// Builds statistical profiles and markdown reports fully offline.
struct ReportBuilder {
    let engine: QueryEngine
    let sheet: SheetInfo
    var arabic: Bool

    init(engine: QueryEngine, arabic: Bool) {
        self.engine = engine
        self.sheet = engine.sheet
        self.arabic = arabic
    }

    /// Fast, allocation-light decimal formatting. Creating a fresh NumberFormatter
    /// per cell (this runs for every numeric cell on every grid render) made
    /// scrolling stutter on large sheets. Output matches the previous formatter:
    /// comma grouping, up to 2 decimals for |d| >= 1000 and up to 4 below that.
    static func formatNumber(_ d: Double) -> String {
        guard d.isFinite else { return String(d) }
        let fractionDigits = abs(d) >= 1000 ? 2 : 4
        let s = String(format: "%.\(fractionDigits)f", d)
        guard let dot = s.firstIndex(of: ".") else { return groupThousands(s) }
        let intPart = groupThousands(String(s[s.startIndex..<dot]))
        var frac = String(s[s.index(after: dot)...])
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? intPart : intPart + "." + frac
    }

    private static func groupThousands(_ intPart: String) -> String {
        var digits = intPart
        var sign = ""
        if let first = digits.first, first == "-" || first == "+" {
            sign = String(first)
            digits.removeFirst()
        }
        guard digits.count > 3 else { return sign + digits }
        var grouped = ""
        var n = 0
        for ch in digits.reversed() {
            if n > 0 && n % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
            n += 1
        }
        return sign + String(grouped.reversed())
    }

    static func formatInt(_ i: Int) -> String { formatNumber(Double(i)) }

    // MARK: Full sheet profile

    func fullReport(query: QuerySpec = QuerySpec(), includeColumns: [Int]? = nil) throws -> String {
        let cols = includeColumns ?? sheet.columns.map { $0.index }
        let filteredCount = try engine.countRows(query)
        var md = ""
        let title = arabic ? "تقرير تحليلي — \(sheet.name)" : "Analytical Report — \(sheet.name)"
        md += "# \(title)\n\n"
        md += arabic
            ? "**عدد الصفوف:** \(ReportBuilder.formatInt(filteredCount)) من \(ReportBuilder.formatInt(sheet.rowCount))  \n**عدد الأعمدة:** \(sheet.columns.count)  \n**التاريخ:** \(ReportBuilder.timestamp())\n\n"
            : "**Rows:** \(ReportBuilder.formatInt(filteredCount)) of \(ReportBuilder.formatInt(sheet.rowCount))  \n**Columns:** \(sheet.columns.count)  \n**Generated:** \(ReportBuilder.timestamp())\n\n"

        if query.isActive {
            md += (arabic ? "**الفلاتر المطبقة:** " : "**Active filters:** ") + describeQuery(query) + "\n\n"
        }

        md += arabic ? "## نظرة عامة على الأعمدة\n\n" : "## Column overview\n\n"
        md += arabic
            ? "| العمود | النوع | مملوء | فارغ | قيم مميزة |\n|---|---|---|---|---|\n"
            : "| Column | Type | Filled | Empty | Distinct |\n|---|---|---|---|---|\n"

        var statsCache: [Int: QueryEngine.ColumnStats] = [:]
        for i in cols {
            let s = try engine.stats(for: i, query: query, includeTop: false)
            statsCache[i] = s
            let empty = max(0, s.total - s.nonEmpty)
            md += "| \(escape(s.name)) | \(s.kind.rawValue) | \(ReportBuilder.formatInt(s.nonEmpty)) | \(ReportBuilder.formatInt(empty)) | \(ReportBuilder.formatInt(s.distinct)) |\n"
        }
        md += "\n"

        // Numeric detail
        let numericCols = cols.filter { sheet.columns[$0].kind == .number }
        if !numericCols.isEmpty {
            md += arabic ? "## إحصاءات الأعمدة الرقمية\n\n" : "## Numeric statistics\n\n"
            md += arabic
                ? "| العمود | المجموع | المتوسط | الوسيط | الأدنى | الأعلى | الانحراف المعياري |\n|---|---|---|---|---|---|---|\n"
                : "| Column | Sum | Average | Median | Min | Max | Std dev |\n|---|---|---|---|---|---|---|\n"
            for i in numericCols {
                let s = try engine.stats(for: i, query: query, includeTop: false)
                statsCache[i] = s
                md += "| \(escape(s.name)) "
                md += "| \(s.sum.map(ReportBuilder.formatNumber) ?? "—") "
                md += "| \(s.avg.map(ReportBuilder.formatNumber) ?? "—") "
                md += "| \(s.median.map(ReportBuilder.formatNumber) ?? "—") "
                md += "| \(s.min?.stringValue ?? "—") "
                md += "| \(s.max?.stringValue ?? "—") "
                md += "| \(s.stdev.map(ReportBuilder.formatNumber) ?? "—") |\n"
            }
            md += "\n"
        }

        // Categorical breakdown
        let textCols = cols.filter { sheet.columns[$0].kind != .number }.prefix(6)
        for i in textCols {
            let s = try engine.stats(for: i, query: query, includeTop: true)
            guard !s.topValues.isEmpty, s.distinct > 1 else { continue }
            md += arabic ? "### أكثر القيم تكرارًا في «\(escape(s.name))»\n\n" : "### Most frequent values in “\(escape(s.name))”\n\n"
            md += arabic ? "| القيمة | العدد | النسبة |\n|---|---|---|\n" : "| Value | Count | Share |\n|---|---|---|\n"
            let denom = max(1, s.nonEmpty)
            for (v, n) in s.topValues.prefix(8) {
                let pct = Double(n) / Double(denom) * 100
                md += "| \(escape(v)) | \(ReportBuilder.formatInt(n)) | \(String(format: "%.1f%%", pct)) |\n"
            }
            md += "\n"
        }

        // Numeric breakdown by the strongest categorical column
        if let groupCol = bestGroupingColumn(stats: statsCache), let measure = numericCols.first {
            let spec = AnalysisSpec(query: query, groupBy: [groupCol], aggregations: [
                Aggregation(function: .sum, columnIndex: measure),
                Aggregation(function: .count, columnIndex: nil)
            ], sortByResultColumn: 1, sortDescending: true, limit: 12)
            let table = try engine.runAnalysis(spec)
            if !table.isEmpty {
                md += arabic
                    ? "## \(escape(sheet.columns[measure].name)) حسب \(escape(sheet.columns[groupCol].name))\n\n"
                    : "## \(escape(sheet.columns[measure].name)) by \(escape(sheet.columns[groupCol].name))\n\n"
                md += markdownTable(table)
                md += "\n"
            }
        }

        // Data quality
        md += arabic ? "## جودة البيانات\n\n" : "## Data quality\n\n"
        var issues: [String] = []
        for i in cols {
            guard let s = statsCache[i] else { continue }
            let empty = max(0, s.total - s.nonEmpty)
            if s.total > 0 {
                let ratio = Double(empty) / Double(s.total)
                if ratio > 0.2 {
                    issues.append(arabic
                        ? "العمود «\(s.name)» به \(String(format: "%.0f%%", ratio * 100)) قيم فارغة."
                        : "Column “\(s.name)” is \(String(format: "%.0f%%", ratio * 100)) empty.")
                }
                if s.distinct == 1 && s.nonEmpty > 1 {
                    issues.append(arabic ? "العمود «\(s.name)» له قيمة واحدة فقط." : "Column “\(s.name)” has a single constant value.")
                }
                if s.kind == .number, let avg = s.avg, let stdev = s.stdev, stdev > 0,
                   let maxV = s.max?.doubleValue, maxV > avg + 4 * stdev {
                    issues.append(arabic
                        ? "قيم شاذة محتملة في «\(s.name)» (أعلى قيمة \(ReportBuilder.formatNumber(maxV)) بعيدة عن المتوسط)."
                        : "Possible outliers in “\(s.name)” (max \(ReportBuilder.formatNumber(maxV)) is far from the mean).")
                }
            }
        }
        if issues.isEmpty {
            md += arabic ? "لا توجد مشاكل واضحة في البيانات.\n\n" : "No obvious data quality issues detected.\n\n"
        } else {
            for i in issues.prefix(12) { md += "- \(i)\n" }
            md += "\n"
        }

        return md
    }

    func bestGroupingColumn(stats: [Int: QueryEngine.ColumnStats]) -> Int? {
        var best: (Int, Int)?
        for (idx, s) in stats where s.kind == .text || s.kind == .boolean || s.kind == .date {
            guard s.distinct >= 2, s.distinct <= max(50, s.total / 20) else { continue }
            if best == nil || s.distinct < best!.1 { best = (idx, s.distinct) }
        }
        return best?.0
    }

    // MARK: Small helpers

    func describeQuery(_ q: QuerySpec) -> String {
        var parts: [String] = []
        if !q.search.isEmpty { parts.append("search “\(q.search)”") }
        for f in q.filters where f.columnIndex < sheet.columns.count {
            let name = sheet.columns[f.columnIndex].name
            switch f.op {
            case .isEmpty, .notEmpty: parts.append("\(name) \(f.op.display)")
            case .between: parts.append("\(name) between \(f.value) and \(f.value2)")
            default: parts.append("\(name) \(f.op.display) \(f.value)")
            }
        }
        for s in q.sorts where s.columnIndex < sheet.columns.count {
            parts.append("sort \(sheet.columns[s.columnIndex].name) \(s.ascending ? "↑" : "↓")")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: q.join == .and ? " AND " : " OR ")
    }

    func markdownTable(_ table: ResultTable, maxRows: Int = 50) -> String {
        guard !table.columns.isEmpty else { return "" }
        var md = "| " + table.columns.map(escape).joined(separator: " | ") + " |\n"
        md += "|" + table.columns.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in table.rows.prefix(maxRows) {
            md += "| " + row.map { escape(formatCell($0)) }.joined(separator: " | ") + " |\n"
        }
        if table.rows.count > maxRows {
            md += "\n_… \(table.rows.count - maxRows) more rows_\n"
        }
        return md
    }

    func formatCell(_ v: DBValue) -> String {
        switch v {
        case .double(let d): return ReportBuilder.formatNumber(d)
        case .int(let i): return ReportBuilder.formatInt(Int(i))
        default: return v.stringValue
        }
    }

    func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date())
    }

    /// Compact numeric context handed to the AI so it never sees raw rows.
    func aiContext(query: QuerySpec) throws -> String {
        var lines: [String] = []
        lines.append("sheet: \(sheet.name)")
        lines.append("rows: \(sheet.rowCount)")
        for c in sheet.columns.prefix(40) {
            let s = try engine.stats(for: c.index, query: query, includeTop: c.kind != .number)
            var line = "- [\(c.index)] \(c.name) (\(c.kind.rawValue)): filled=\(s.nonEmpty), distinct=\(s.distinct)"
            if let sum = s.sum { line += ", sum=\(ReportBuilder.formatNumber(sum))" }
            if let avg = s.avg { line += ", avg=\(ReportBuilder.formatNumber(avg))" }
            if let med = s.median { line += ", median=\(ReportBuilder.formatNumber(med))" }
            if let mn = s.min { line += ", min=\(mn.stringValue)" }
            if let mx = s.max { line += ", max=\(mx.stringValue)" }
            if !s.topValues.isEmpty {
                let top = s.topValues.prefix(5).map { "\($0.0)×\($0.1)" }.joined(separator: ", ")
                line += ", top=[\(top)]"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Markdown -> HTML (small, dependency free)

enum MarkdownRenderer {
    static func html(from markdown: String, rtl: Bool) -> String {
        var body = ""
        var inTable = false
        var inList = false

        func closeBlocks() {
            if inTable { body += "</tbody></table>\n"; inTable = false }
            if inList { body += "</ul>\n"; inList = false }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeBlocks(); continue }

            if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .dropFirst().dropLast()
                if cells.allSatisfy({ $0.allSatisfy { c in c == "-" || c == ":" } }) && !cells.isEmpty {
                    continue
                }
                if !inTable {
                    body += "<table><thead><tr>" + cells.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>\n"
                    inTable = true
                } else {
                    body += "<tr>" + cells.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                }
                continue
            } else if inTable {
                body += "</tbody></table>\n"; inTable = false
            }

            if line.hasPrefix("### ") { closeBlocks(); body += "<h3>\(inline(String(line.dropFirst(4))))</h3>\n" }
            else if line.hasPrefix("## ") { closeBlocks(); body += "<h2>\(inline(String(line.dropFirst(3))))</h2>\n" }
            else if line.hasPrefix("# ") { closeBlocks(); body += "<h1>\(inline(String(line.dropFirst(2))))</h1>\n" }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !inList { body += "<ul>\n"; inList = true }
                body += "<li>\(inline(String(line.dropFirst(2))))</li>\n"
            } else {
                if inList { body += "</ul>\n"; inList = false }
                body += "<p>\(inline(line))</p>\n"
            }
        }
        closeBlocks()

        return """
        <!doctype html><html dir="\(rtl ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; margin: 20px; line-height: 1.55; font-size: 15px; }
        h1 { font-size: 24px; margin-bottom: 4px; }
        h2 { font-size: 19px; margin-top: 26px; border-bottom: 1px solid rgba(128,128,128,.3); padding-bottom: 4px; }
        h3 { font-size: 16px; margin-top: 20px; }
        table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 13px; }
        th, td { border: 1px solid rgba(128,128,128,.35); padding: 6px 8px; text-align: \(rtl ? "right" : "left"); }
        th { background: rgba(0,122,255,.12); font-weight: 600; }
        tr:nth-child(even) td { background: rgba(128,128,128,.07); }
        code { background: rgba(128,128,128,.15); padding: 1px 4px; border-radius: 4px; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    private static func inline(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        out = out.replacingOccurrences(of: "`(.+?)`", with: "<code>$1</code>", options: .regularExpression)
        out = out.replacingOccurrences(of: "_(.+?)_", with: "<em>$1</em>", options: .regularExpression)
        return out
    }
}
