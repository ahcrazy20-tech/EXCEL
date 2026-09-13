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
    @State private var usedProvider: String?

    private let recipe: SavedAnalysisRecipe?
    @State private var replayPlan: CommandPlan?
    @State private var runTask: Task<Void, Never>?
    @State private var runID = UUID()
    @State private var completedCommand = ""
    @State private var output: AnalysisOutput?
    @State private var includeNarrative = false
    @State private var showSaveAnalysis = false
    @State private var analysisTitle = ""
    @State private var savingAnalysis = false
    @State private var savedNotice = false

    init(vm: SheetViewModel, recipe: SavedAnalysisRecipe? = nil) {
        self.vm = vm
        self.recipe = recipe
        _command = State(initialValue: recipe?.command ?? "")
        _replayPlan = State(initialValue: recipe?.plan)
    }

    private var suggestions: [String] {
        NLQueryParser.suggestions(for: vm.sheet, arabic: settings.language == .ar)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputCard
                    if running {
                        HStack {
                            ProgressView()
                            Text("ask.thinking".loc)
                            Spacer()
                            Button("common.cancel".loc) { cancelRun() }
                        }.padding(.horizontal)
                    }
                    if savedNotice {
                        Label("analysis.savedOK".loc, systemImage: "bookmark.fill")
                            .font(.caption).foregroundStyle(.green).padding(.horizontal)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    if let plan { planCard(plan) }
                    if let narrative { narrativeCard(narrative) }
                    if let result { resultCard(result) }
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
            .alert("analysis.save".loc, isPresented: $showSaveAnalysis) {
                TextField("analysis.name".loc, text: $analysisTitle)
                Button("settings.save".loc) { saveAnalysis() }
                Button("common.cancel".loc, role: .cancel) {}
            } message: { Text("analysis.saveHint".loc) }
        }
        .onDisappear { cancelRun(showMessage: false) }
        .onChange(of: command) { text in
            if text != recipe?.command { replayPlan = nil }
            if text != completedCommand {
                plan = nil; result = nil; narrative = nil; output = nil; savedNotice = false
            }
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
                .disabled(running || savingAnalysis)

            HStack {
                Picker("", selection: $useAI) {
                    Text("ask.offline".loc).tag(false)
                    Text("ask.ai".loc).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .disabled(!settings.hasAI || running || replayPlan != nil)

                Spacer()

                Button(action: run) {
                    Label("ask.run".loc, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running || savingAnalysis)
            }
            if replayPlan != nil {
                Label("analysis.replay".loc, systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if useAI {
                Toggle("analysis.narrate".loc, isOn: $includeNarrative).font(.caption).disabled(running)
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
                if let usedProvider {
                    Text("\("ai.usedProvider".loc): \(usedProvider)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("analysis.localResult".loc).font(.caption2).foregroundStyle(.secondary)
            }
            Text(plan.explanation.isEmpty ? plan.kind.rawValue : plan.explanation)
                .font(.subheadline)
            if !plan.sql.isEmpty {
                Text(plan.sql).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
            }
            if let output {
                Text("\(vm.sheet.name) · " + String(format: "analysis.elapsed".loc, output.elapsed))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(output.completedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if plan.kind == .filterRows || plan.kind == .topN {
                    Button {
                        vm.apply(query: plan.analysis.query)
                        dismiss()
                    } label: { Label("ask.applyToSheet".loc, systemImage: "arrow.down.doc") }
                        .font(.caption).buttonStyle(.bordered)
                }
                HStack {
                    Button { saveAsReport() } label: {
                        Label("ask.saveResult".loc, systemImage: "square.and.arrow.down")
                    }
                    Button {
                        analysisTitle = String(completedCommand.prefix(120))
                        showSaveAnalysis = true
                    } label: { Label("analysis.save".loc, systemImage: "bookmark") }
                }
                .font(.caption).buttonStyle(.bordered)
                .disabled(running || savingAnalysis)
                if savingAnalysis { ProgressView("ai.saving".loc) }
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
                Text(String(format: "analysis.previewRows".loc, min(100, table.rows.count), table.rows.count))
                    .font(.caption2).foregroundStyle(.secondary)
                Menu {
                    Button("CSV") { export(table, .csv) }
                    Button("XLSX") { export(table, .xlsx) }
                    Button("JSON") { export(table, .json) }
                } label: { Image(systemName: "square.and.arrow.up").font(.caption) }
            }
            if table.isEmpty { Text("sheet.noResults".loc).foregroundStyle(.secondary) }
            if table.truncated {
                Label("analysis.truncated".loc, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ResultTableView(table: table)
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: Actions

    private func cancelRun(showMessage: Bool = true) {
        runID = UUID()
        runTask?.cancel()
        runTask = nil
        if running && showMessage { errorText = "analysis.cancelled".loc }
        running = false
    }

    private func run() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, !savingAnalysis else { return }
        cancelRun(showMessage: false)
        let id = runID
        running = true
        errorText = nil
        result = nil
        narrative = nil
        plan = nil
        output = nil
        savedNotice = false
        usedProvider = nil
        settings.haptic()

        let sheet = vm.sheet
        let path = vm.engine.db.path
        let arabic = settings.language == .ar
        let savedPlan = replayPlan
        let ai: AIRouter? = (savedPlan == nil && settings.hasAI && useAI) ? settings.aiRouter : nil
        let narrate = includeNarrative

        runTask = Task { @MainActor in
            defer { if runID == id { running = false; runTask = nil } }
            do {
                let computedPlan: CommandPlan
                if let savedPlan {
                    try recipe?.validate(for: sheet)
                    computedPlan = savedPlan
                } else if let ai {
                    computedPlan = try await ai.plan(command: text, sheet: sheet)
                } else {
                    computedPlan = NLQueryParser(sheet: sheet).parse(text)
                }
                try Task.checkCancellation()
                let executed = try await AnalysisRunner.execute(plan: computedPlan, path: path, sheet: sheet, arabic: arabic)
                try Task.checkCancellation()
                guard runID == id else { return }
                plan = computedPlan
                result = executed.table
                narrative = executed.report
                output = executed
                completedCommand = text
                usedProvider = ai?.lastUsedProvider?.display

                if narrate, let ai, let table = executed.table, !table.isEmpty {
                    let builder = ReportBuilder(engine: vm.engine, arabic: arabic)
                    let context = "QUESTION: \(text)\nRESULT PREVIEW (may be truncated):\n"
                        + builder.markdownTable(table, maxRows: 25)
                    let answer = try await ai.ask(question: text, context: context, language: arabic ? "ar" : "en")
                    try Task.checkCancellation()
                    guard runID == id else { return }
                    narrative = answer
                }
            } catch {
                guard runID == id, !Task.isCancelled else { return }
                errorText = error.localizedDescription
            }
        }
    }

    private func saveAnalysis() {
        guard let plan, !savingAnalysis else { return }
        let recipe = SavedAnalysisRecipe(sheet: vm.sheet, command: completedCommand, plan: plan)
        let sheet = vm.sheet
        let title = analysisTitle
        let workspace = Workspace.shared
        savingAnalysis = true
        Task { @MainActor in
            defer { savingAnalysis = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try workspace.saveAnalysis(title: title, recipe: recipe, sheet: sheet)
                }.value
                savedNotice = true
                settings.haptic(.medium)
            } catch { errorText = error.localizedDescription }
        }
    }

    private func saveAsReport() {
        let arabic = settings.language == .ar
        let builder = ReportBuilder(engine: vm.engine, arabic: arabic)
        var md = "# \(completedCommand)\n\n"
        md += "\(vm.sheet.name) · \(Date().formatted())\n\n"
        if let plan { md += "_\(plan.explanation)_\n\n" }
        if let narrative { md += narrative + "\n\n" }
        if let result {
            if result.truncated || result.rows.count > 200 { md += "\("analysis.truncated".loc)\n\n" }
            md += builder.markdownTable(result, maxRows: 200)
        }
        library.saveReport(sheetID: vm.sheet.id, title: completedCommand, body: md)
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
