import SwiftUI

struct ReportsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var selected: Workspace.StoredReport?

    var body: some View {
        NavigationStack {
            Group {
                if library.reports.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 54)).foregroundStyle(.tint)
                        Text("report.empty".loc)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(library.reports) { report in
                            Button {
                                selected = report
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(report.title).font(.body.weight(.medium)).lineLimit(1)
                                    Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    library.deleteReport(report.id)
                                } label: { Label("report.delete".loc, systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("report.title".loc)
            .sheet(item: $selected) { report in
                ReportDetailView(report: report)
            }
        }
    }
}

struct ReportDetailView: View {
    let report: Workspace.StoredReport
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) var dismiss
    @State private var shareItem: ShareItem?
    @State private var aiBusy = false
    @State private var aiText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let aiText {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("report.aiNarrative".loc, systemImage: "sparkles").font(.caption.bold())
                            MarkdownTextView(markdown: aiText)
                        }
                        .padding()
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    MarkdownTextView(markdown: report.body)
                }
                .padding()
            }
            .navigationTitle(report.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if settings.hasAI {
                        Button {
                            narrate()
                        } label: {
                            if aiBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        }
                        .disabled(aiBusy)
                    }
                    Menu {
                        Button("Markdown") { share(.markdown) }
                        Button("HTML") { share(.html) }
                        Button("PDF") { share(.pdf) }
                        Button("Copy") { UIPasteboard.general.string = report.body }
                    } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        }
    }

    private func share(_ format: ExportFormat) {
        do {
            let arabic = settings.language == .ar
            switch format {
            case .markdown:
                shareItem = ShareItem(url: try Exporter.text(report.body, name: report.title, ext: "md"))
            case .html:
                let html = MarkdownRenderer.html(from: report.body, rtl: arabic)
                shareItem = ShareItem(url: try Exporter.text(html, name: report.title, ext: "html"))
            default:
                let html = MarkdownRenderer.html(from: report.body, rtl: arabic)
                shareItem = ShareItem(url: try Exporter.pdf(html: html, name: report.title))
            }
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }

    private func narrate() {
        aiBusy = true
        let client = settings.aiRouter
        let body = String(report.body.prefix(9000))
        let lang = settings.language.rawValue
        Task {
            do {
                let text = try await client.narrate(reportContext: body, language: lang)
                await MainActor.run { aiText = text; aiBusy = false }
            } catch {
                await MainActor.run {
                    library.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    aiBusy = false
                }
            }
        }
    }
}

/// Minimal markdown presenter: headings, bold, bullets, numbered lists,
/// code blocks and tables. Used for stored reports and AI narratives,
/// which arrive as raw markdown and must not be shown with literal `**`/`|`.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(attributed(text))
                        .font(level == 1 ? .title2.bold() : (level == 2 ? .headline : .subheadline.bold()))
                        .padding(.top, level == 1 ? 0 : 8)
                case .paragraph(let text):
                    Text(attributed(text)).font(.subheadline)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.subheadline)
                        Text(attributed(text)).font(.subheadline)
                    }
                case .numbered(let n, let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(n).").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Text(attributed(text)).font(.subheadline)
                    }
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text).font(.caption.monospaced())
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, cells in
                                HStack(spacing: 0) {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(attributed(cell))
                                            .font(i == 0 ? .caption.bold() : .caption)
                                            .lineLimit(1)
                                            .frame(width: 120, alignment: .leading)
                                            .padding(5)
                                    }
                                }
                                .background(i == 0 ? Color.accentColor.opacity(0.12)
                                            : (i % 2 == 0 ? Color.clear : Color.secondary.opacity(0.06)))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func attributed(_ s: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(Int, String)
        case code(String)
        case table([[String]])
    }

    /// Strips a single outer code fence — AI models sometimes wrap whole
    /// markdown answers in ```markdown … ```.
    private var source: String {
        let t = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), t.contains("\n"),
              let firstNL = t.firstIndex(of: "\n") else { return markdown }
        let innerStart = t.index(after: firstNL)
        let innerEnd = t.index(t.endIndex, offsetBy: -3)
        guard innerStart < innerEnd else { return markdown }
        let inner = t[innerStart..<innerEnd]
        // Only unwrap when the fence wraps the WHOLE answer (no other fences inside).
        guard !inner.contains("```") else { return markdown }
        return String(inner)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var tableRows: [[String]] = []
        var codeLines: [String] = []
        var inCode = false

        func flushTable() {
            if !tableRows.isEmpty { out.append(.table(tableRows)); tableRows = [] }
        }
        func flushCode() {
            if !codeLines.isEmpty { out.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushTable()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(raw)
                continue
            }
            if line.isEmpty { flushTable(); continue }
            if line.hasPrefix("|") {
                var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
                if line.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
                if cells.allSatisfy({ $0.allSatisfy { c in c == "-" || c == ":" } }) { continue }
                if !cells.isEmpty { tableRows.append(cells) }
                continue
            }
            flushTable()
            if line.hasPrefix("### ") { out.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if let (n, item) = numberedItem(line) { out.append(.numbered(n, item)) }
            else { out.append(.paragraph(line)) }
        }
        flushCode()
        flushTable()
        return out
    }

    /// Matches `1. text` — requires a space after the dot so "1.5 million" stays a paragraph.
    private func numberedItem(_ line: String) -> (Int, String)? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let num = line[line.startIndex..<dot]
        guard !num.isEmpty, num.allSatisfy(\.isNumber), let n = Int(num) else { return nil }
        let rest = line[line.index(after: after)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (n, rest)
    }
}
