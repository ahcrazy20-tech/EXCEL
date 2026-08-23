import Foundation

/// How the first rows of an imported sheet should be treated.
enum HeaderMode: String, CaseIterable, Identifiable {
    /// Smart detection: find the row that actually looks like a header
    /// (skipping title/blank rows above it) and use it as the column names.
    case auto
    /// The first non-empty row is always the header (previous behaviour).
    case always
    /// No header at all: generic `Column A, Column B…` names, every row is data.
    case none

    var id: String { rawValue }

    var display: String {
        switch self {
        case .auto: return "files.headerMode.auto".loc
        case .always: return "files.headerMode.always".loc
        case .none: return "files.headerMode.none".loc
        }
    }
}

struct HeaderDecision {
    /// Column names derived from the chosen header row (padded later by callers).
    var header: [String]
    /// Index of the header row inside the sample buffer, or nil when no header was found.
    /// Rows above the header index are dropped (report titles, blank spacer rows…).
    var headerIndex: Int?
}

/// Heuristic header-row detection.
///
/// A row is considered a header when it is mostly non-numeric, non-duplicated
/// text, reasonably wide, and — when rows below exist — contrasts with them
/// (text labels above numbers/dates). Numeric rows never qualify, which keeps
/// pure data tables without headers intact.
enum HeaderDetector {
    /// How many leading rows are buffered before a decision is forced.
    static let sampleLimit = 30
    /// How deep into the sheet we look for a header row.
    static let scanDepth = 5

    static func decide(mode: HeaderMode, buffer: [[DBValue]]) -> HeaderDecision {
        switch mode {
        case .always:
            guard let first = buffer.first else { return HeaderDecision(header: [], headerIndex: nil) }
            return HeaderDecision(header: names(from: first), headerIndex: 0)
        case .none:
            let width = buffer.map { $0.count }.max() ?? 1
            return HeaderDecision(header: genericNames(width: width), headerIndex: nil)
        case .auto:
            guard let idx = detect(in: buffer) else {
                let width = buffer.map { $0.count }.max() ?? 1
                return HeaderDecision(header: genericNames(width: width), headerIndex: nil)
            }
            return HeaderDecision(header: names(from: buffer[idx]), headerIndex: idx)
        }
    }

    /// Returns the index (into `rows`) of the row that looks like a header, or nil.
    static func detect(in rows: [[DBValue]]) -> Int? {
        guard !rows.isEmpty else { return nil }
        let width = max(1, rows.map { $0.count }.max() ?? 1)
        let lastCandidate = min(scanDepth, rows.count) - 1
        for i in 0...max(0, lastCandidate) {
            let below = rows[(i + 1)...]
            if looksLikeHeader(rows[i], at: i, width: width, below: below) { return i }
        }
        return nil
    }

    // MARK: - Heuristics

    private static func looksLikeHeader(_ row: [DBValue], at index: Int, width: Int,
                                        below: ArraySlice<[DBValue]>) -> Bool {
        let nonEmpty = row.filter { !$0.isEmptyText }
        let minLabels = width <= 1 ? 1 : 2
        // Blank rows and single-cell title rows never qualify.
        guard nonEmpty.count >= minLabels else { return false }

        // Headers are labels: mostly text, not numbers.
        let textCount = nonEmpty.filter { !isNumericish($0) }.count
        let textFrac = Double(textCount) / Double(nonEmpty.count)
        guard textFrac >= 0.6 else { return false }

        // Repeated values ("0,0,0", "N/A,N/A") are data, not headers.
        let distinct = Set(nonEmpty.map { $0.stringValue }).count
        let distinctFrac = Double(distinct) / Double(nonEmpty.count)
        guard distinctFrac >= 0.8 else { return false }

        // A header spans the table; rows covering less than half the width are skipped
        // (merged report titles etc.).
        let fillFrac = Double(nonEmpty.count) / Double(width)
        guard fillFrac >= 0.5 else { return false }

        // Contrast with the rows below: labels above numbers/dates is a strong signal.
        if !below.isEmpty {
            var checked = 0
            var numericBelow = 0
            for lower in below.prefix(12) {
                for (c, hv) in row.enumerated() where !hv.isEmptyText && !isNumericish(hv) {
                    guard c < lower.count else { continue }
                    let lv = lower[c]
                    if !lv.isEmptyText {
                        checked += 1
                        if isNumericish(lv) || looksLikeDate(lv) { numericBelow += 1 }
                    }
                }
            }
            // No type contrast at all (everything below is plain text): only trust the very
            // first row, or a "strong" deeper row — deeper candidates are only reached when
            // the rows above them looked like titles/blank rows, so dropping them is safe.
            if checked >= 6, Double(numericBelow) / Double(checked) < 0.15 {
                let strong = textFrac >= 0.9 && distinctFrac >= 1.0 && fillFrac >= 0.8
                if !(index == 0 || strong) { return false }
            }
        }
        return true
    }

    private static func isNumericish(_ v: DBValue) -> Bool {
        switch v {
        case .int, .double:
            return true
        case .null:
            return false
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let first = t.first else { return false }
            guard first.isNumber || first == "-" || first == "+" || first == "." else { return false }
            return Double(t.replacingOccurrences(of: ",", with: "")) != nil
        }
    }

    private static func looksLikeDate(_ v: DBValue) -> Bool {
        if case .text(let s) = v {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.count >= 8 && t.contains("-") && t.first?.isNumber == true
        }
        return false
    }

    // MARK: - Names

    static func names(from row: [DBValue]) -> [String] {
        row.enumerated().map { idx, v in
            let s = v.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "Column \(CellRef.name(forIndex: idx))" : s
        }
    }

    static func genericNames(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return (0..<width).map { "Column \(CellRef.name(forIndex: $0))" }
    }
}
