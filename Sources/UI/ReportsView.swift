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
                            Text(aiText).font(.subheadline).textSelection(.enabled)
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
        let client = AIClient(config: settings.aiConfig)
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

/// Minimal markdown presenter: headings, bold, bullets and tables.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(text)
                        .font(level == 1 ? .title2.bold() : (level == 2 ? .headline : .subheadline.bold()))
                        .padding(.top, level == 1 ? 0 : 8)
                case .paragraph(let text):
                    Text(attributed(text)).font(.subheadline)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(attributed(text)).font(.subheadline)
                    }
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, cells in
                                HStack(spacing: 0) {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(cell)
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
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case table([[String]])
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var tableRows: [[String]] = []

        func flushTable() {
            if !tableRows.isEmpty { out.append(.table(tableRows)); tableRows = [] }
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushTable(); continue }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .dropFirst().dropLast()
                if cells.allSatisfy({ $0.allSatisfy { c in c == "-" || c == ":" } }) { continue }
                tableRows.append(Array(cells))
                continue
            }
            flushTable()
            if line.hasPrefix("### ") { out.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else { out.append(.paragraph(line)) }
        }
        flushTable()
        return out
    }
}
