import SwiftUI

struct AskView: View {
    @ObservedObject var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) var dismiss

    @State private var command = ""
    @State private var useAI = false
    @State private var running = false
    @State private var plan: CommandPlan?
    @State private var result: ResultTable?
    @State private var narrative: String?
    @State private var errorText: String?
    @State private var shareItem: ShareItem?

    private var suggestions: [String] {
        NLQueryParser.suggestions(for: vm.sheet, arabic: settings.language == .ar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputCard
                    if running { HStack { ProgressView(); Text("ask.thinking".loc) }.padding(.horizontal) }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    if let plan { planCard(plan) }
                    if let narrative { narrativeCard(narrative) }
                    if let result, !result.isEmpty { resultCard(result) }
                    if plan == nil && !running { suggestionCard }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("ask.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() } }
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        }
    }

    // MARK: Cards

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("ask.placeholder".loc, text: $command, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .onSubmit(run)

            HStack {
                Picker("", selection: $useAI) {
                    Text("ask.offline".loc).tag(false)
                    Text("ask.ai".loc).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .disabled(!settings.hasAI)

                Spacer()

                Button(action: run) {
                    Label("ask.run".loc, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
            }
            if !settings.hasAI {
                Text("settings.aiNote".loc).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ask.suggestions".loc).font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button {
                    command = s
                    run()
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars").font(.caption)
                        Text(s).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func planCard(_ plan: CommandPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                Text("ask.plan".loc).font(.caption.bold())
                Spacer()
                Text("\(Int(plan.confidence * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
            Text(plan.explanation.isEmpty ? plan.kind.rawValue : plan.explanation)
                .font(.subheadline)
            if !plan.sql.isEmpty {
                Text(plan.sql).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack {
                Button {
                    var q = plan.analysis.query
                    if plan.kind == .topN { q.sorts = plan.analysis.query.sorts }
                    vm.apply(query: q)
                    dismiss()
                } label: { Label("ask.applyToSheet".loc, systemImage: "arrow.down.doc") }
                    .font(.caption)
                    .buttonStyle(.bordered)

                Button {
                    saveAsReport()
                } label: { Label("ask.saveResult".loc, systemImage: "square.and.arrow.down") }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func narrativeCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("report.aiNarrative".loc, systemImage: "sparkles").font(.caption.bold())
            Text(text).font(.subheadline).textSelection(.enabled)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func resultCard(_ table: ResultTable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ask.result".loc).font(.caption.bold())
                Spacer()
                Text("\(table.rows.count) \("ask.rowsShown".loc)").font(.caption2).foregroundStyle(.secondary)
                Menu {
                    Button("CSV") { export(table, .csv) }
                    Button("XLSX") { export(table, .xlsx) }
                    Button("JSON") { export(table, .json) }
                } label: { Image(systemName: "square.and.arrow.up").font(.caption) }
            }
            ResultTableView(table: table)
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: Actions

    private func run() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        running = true
        errorText = nil
        result = nil
        narrative = nil
        plan = nil
        settings.haptic()

        let engine = vm.engine
        let sheet = vm.sheet
        let arabic = settings.language == .ar
        let ai: AIClient? = (settings.hasAI && useAI) ? AIClient(config: settings.aiConfig) : nil

        Task {
            do {
                var computedPlan: CommandPlan
                if let ai {
                    let sampleRows = (try? engine.fetchRows(QuerySpec(), offset: 0, limit: 3)) ?? []
                    let sample = ResultTable(columns: sheet.columns.map { $0.name },
                                             rows: sampleRows.map { Array($0.dropFirst()) })
                    computedPlan = try await ai.plan(command: text, sheet: sheet, sample: sample)
                } else {
                    computedPlan = NLQueryParser(sheet: sheet).parse(text)
                }

                let executed = try await Self.execute(plan: computedPlan, engine: engine, arabic: arabic)

                await MainActor.run {
                    plan = computedPlan
                    result = executed.0
                    narrative = executed.1
                    running = false
                }

                // Optional AI narration of computed numbers.
                if let ai, let table = executed.0, !table.isEmpty, computedPlan.kind != .summary {
                    let builder = ReportBuilder(engine: engine, arabic: arabic)
                    let ctx = "QUESTION: \(text)\nRESULT TABLE:\n" + builder.markdownTable(table, maxRows: 25)
                    if let answer = try? await ai.ask(question: text, context: ctx, language: arabic ? "ar" : "en") {
                        await MainActor.run { narrative = answer }
                    }
                }
            } catch {
                await MainActor.run {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    running = false
                }
            }
        }
    }

    /// Executes a plan and returns (table, narrative markdown).
    static func execute(plan: CommandPlan, engine: QueryEngine, arabic: Bool) async throws -> (ResultTable?, String?) {
        try await Task.detached(priority: .userInitiated) { () -> (ResultTable?, String?) in
            let builder = ReportBuilder(engine: engine, arabic: arabic)
            switch plan.kind {
            case .summary:
                let md = try builder.fullReport(query: plan.analysis.query)
                return (nil, md)
            case .duplicates:
                let table = try engine.duplicateGroups(columns: plan.analysis.groupBy.isEmpty
                                                       ? [engine.sheet.columns.first?.index ?? 0]
                                                       : plan.analysis.groupBy,
                                                       limit: max(20, plan.analysis.limit))
                return (table, nil)
            case .aggregate, .chart:
                let table = try engine.runAnalysis(plan.analysis)
                return (table, nil)
            case .sql:
                let table = try engine.runSQL(plan.sql)
                return (table, nil)
            case .topN, .filterRows:
                var q = plan.analysis.query
                if plan.kind == .topN { q.sorts = plan.analysis.query.sorts }
                let limit = max(1, min(plan.analysis.limit, 500))
                let rows = try engine.fetchRows(q, offset: 0, limit: limit)
                let table = ResultTable(columns: engine.sheet.columns.map { $0.name },
                                        rows: rows.map { Array($0.dropFirst()) })
                return (table, nil)
            }
        }.value
    }

    private func saveAsReport() {
        let arabic = settings.language == .ar
        let builder = ReportBuilder(engine: vm.engine, arabic: arabic)
        var md = "# \(command)\n\n"
        if let plan { md += "_\(plan.explanation)_\n\n" }
        if let narrative { md += narrative + "\n\n" }
        if let result { md += builder.markdownTable(result, maxRows: 200) }
        library.saveReport(sheetID: vm.sheet.id, title: command, body: md)
        settings.haptic(.medium)
        dismiss()
    }

    private func export(_ table: ResultTable, _ format: ExportFormat) {
        do {
            let url: URL
            switch format {
            case .xlsx: url = try Exporter.xlsx(table: table, name: "SheetX Result")
            case .json: url = try Exporter.json(table: table, name: "SheetX Result")
            default: url = try Exporter.csv(table: table, name: "SheetX Result")
            }
            shareItem = ShareItem(url: url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Simple scrollable result table

struct ResultTableView: View {
    let table: ResultTable
    var maxRows = 100

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                        Text(c)
                            .font(.caption.bold())
                            .frame(width: 130, alignment: .leading)
                            .padding(6)
                            .background(Color.accentColor.opacity(0.12))
                    }
                }
                ForEach(Array(table.rows.prefix(maxRows).enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                            Text(format(v))
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                                .frame(width: 130, alignment: .leading)
                                .padding(6)
                        }
                    }
                    .background(i % 2 == 0 ? Color.clear : Color.secondary.opacity(0.07))
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func format(_ v: DBValue) -> String {
        switch v {
        case .double(let d): return ReportBuilder.formatNumber(d)
        case .int(let i): return ReportBuilder.formatInt(Int(i))
        default: return v.stringValue
        }
    }
}
