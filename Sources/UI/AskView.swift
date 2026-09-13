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
    @State private var showOptions = false
    @State private var showResultExplorer = false
    @State private var processingResult = false
    @State private var textDetail: AskTextDetail?
    @FocusState private var questionFocused: Bool

    init(vm: SheetViewModel, recipe: SavedAnalysisRecipe? = nil) {
        self.vm = vm
        self.recipe = recipe
        _command = State(initialValue: recipe?.command ?? "")
        _replayPlan = State(initialValue: recipe?.plan)
    }

    #if DEBUG
    // Deterministic UI regression input; never present in the unsigned Release IPA.
    init(layoutTestModel vm: SheetViewModel, result: ResultTable, narrative: String) {
        self.vm = vm
        recipe = nil
        _command = State(initialValue: "Large result layout test")
        _completedCommand = State(initialValue: "Large result layout test")
        _plan = State(initialValue: CommandPlan())
        _result = State(initialValue: result)
        _narrative = State(initialValue: narrative)
    }
    #endif

    private var suggestions: [String] {
        NLQueryParser.suggestions(for: vm.sheet, arabic: settings.language == .ar)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if running {
                            HStack { ProgressView(); Text("ask.thinking".loc).font(.caption) }.padding(.horizontal)
                        }
                        if savedNotice {
                            Label("analysis.savedOK".loc, systemImage: "bookmark.fill")
                                .font(.caption).foregroundStyle(.green).padding(.horizontal)
                        }
                        if let errorText {
                            VStack(alignment: .leading) {
                                Label(String(errorText.prefix(500)), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red).lineLimit(5)
                                Button("ask.readFull".loc) {
                                    textDetail = AskTextDetail(title: "common.error".loc, text: errorText)
                                }.font(.caption)
                            }.padding(.horizontal)
                        }
                        if let plan { planCard(plan) }
                        if let narrative { narrativeCard(narrative) }
                        if let result { resultCard(result) }
                        if plan == nil && !running { suggestionCard }
                    }
                    .padding(.vertical, 12)
                    .frame(width: geometry.size.width, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputCard.padding(12).background(.regularMaterial)
            }
            .navigationTitle("ask.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) { questionFocused = false; cancelRun(showMessage: false); dismiss() }
                        .accessibilityIdentifier("ask.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { questionFocused = false; showOptions = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }.accessibilityLabel("ask.options".loc).accessibilityIdentifier("ask.options")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("common.done".loc) { questionFocused = false }
                }
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
            .sheet(item: $textDetail) { detail in LongTextView(title: detail.title, text: detail.text) }
            .sheet(isPresented: $showOptions) { optionsView }
            .sheet(isPresented: $showResultExplorer) {
                if let result { ResultExplorerView(table: result).presentationDetents([.large]) }
            }
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

    // The composer is not part of the result scroll view. Run, Cancel, keyboard
    // dismissal and options stay reachable regardless of result dimensions.
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("ask.placeholder".loc, text: $command, axis: .vertical)
                .lineLimit(1...(running ? 1 : 3))
                .textFieldStyle(.roundedBorder)
                .submitLabel(.go)
                .focused($questionFocused)
                .onSubmit(run)
                .disabled(running || savingAnalysis || processingResult)
                .accessibilityIdentifier("ask.question")
            HStack(spacing: 10) {
                Button { questionFocused = false; showOptions = true } label: {
                    Label(useAI && replayPlan == nil ? "ask.ai".loc : "ask.offline".loc,
                          systemImage: useAI && replayPlan == nil ? "sparkles" : "iphone")
                        .lineLimit(1)
                }.font(.caption)
                Spacer(minLength: 0)
                if processingResult || savingAnalysis { ProgressView() }
                if running {
                    Button("common.cancel".loc) { cancelRun() }
                        .buttonStyle(.bordered).accessibilityIdentifier("ask.cancel")
                } else {
                    Button(action: run) { Label("ask.run".loc, systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savingAnalysis || processingResult)
                        .accessibilityIdentifier("ask.run")
                }
            }
        }
    }

    private var optionsView: some View {
        NavigationStack {
            Form {
                Section("ask.options".loc) {
                    Picker("settings.provider".loc, selection: $useAI) {
                        Text("ask.offline".loc).tag(false)
                        Text("ask.ai".loc).tag(true)
                    }
                    .disabled(!settings.hasAI || running || replayPlan != nil)
                    if useAI {
                        Toggle("analysis.narrate".loc, isOn: $includeNarrative).disabled(running)
                    }
                    if replayPlan != nil { Text("analysis.replay".loc).font(.caption) }
                    Text("settings.aiNote".loc).font(.caption).foregroundStyle(.secondary)
                    if !settings.hasAI { Text("ai.none".loc).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("ask.options".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".loc) { showOptions = false }.accessibilityIdentifier("ask.options.done")
                }
            }
        }
        .presentationDetents([.large])
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
            Text(String((plan.explanation.isEmpty ? plan.kind.rawValue : plan.explanation).prefix(700)))
                .font(.subheadline).lineLimit(4)
            if !plan.sql.isEmpty {
                Text(String(plan.sql.prefix(1000))).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                Button("ask.readFull".loc) { textDetail = AskTextDetail(title: "ask.plan".loc, text: plan.sql) }
                    .font(.caption)
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
                VStack(alignment: .leading, spacing: 8) {
                    Button { saveAsReport() } label: {
                        Label("ask.saveResult".loc, systemImage: "square.and.arrow.down")
                    }
                    Button {
                        analysisTitle = String(completedCommand.prefix(120))
                        showSaveAnalysis = true
                    } label: { Label("analysis.save".loc, systemImage: "bookmark") }
                }
                .font(.caption).buttonStyle(.bordered)
                .disabled(running || savingAnalysis || processingResult)
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
            Text(String(text.prefix(2000))).font(.subheadline).lineLimit(10).textSelection(.enabled)
            Button("ask.readFull".loc) { textDetail = AskTextDetail(title: "report.aiNarrative".loc, text: text) }
                .font(.caption).accessibilityIdentifier("ask.readResponse")
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func resultCard(_ table: ResultTable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ask.result".loc).font(.caption.bold())
            HStack {
                Button { questionFocused = false; showResultExplorer = true } label: {
                    Label("result.expand".loc, systemImage: "arrow.up.left.and.arrow.down.right")
                }.accessibilityIdentifier("ask.expandResult")
                Spacer()
                Menu {
                    Button("CSV") { export(table, .csv) }
                    Button("XLSX") { export(table, .xlsx) }
                    Button("JSON") { export(table, .json) }
                } label: { Image(systemName: "square.and.arrow.up").padding(8) }
                    .accessibilityLabel("sheet.export".loc).disabled(processingResult)
            }.font(.caption)
            if table.isEmpty { Text("sheet.noResults".loc).foregroundStyle(.secondary) }
            if table.truncated {
                Label("analysis.truncated".loc, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ResultTableView(table: table).id(output?.completedAt)
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
        guard !text.isEmpty, !running, !savingAnalysis, !processingResult else { return }
        questionFocused = false
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
        let savedPlan = text == recipe?.command ? replayPlan : nil
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
                    computedPlan = await Task.detached(priority: .userInitiated) {
                        NLQueryParser(sheet: sheet).parse(text)
                    }.value
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
                    let context = await Task.detached(priority: .userInitiated) {
                        let preview = builder.markdownTable(table, maxRows: 25)
                        return "QUESTION: \(text)\nRESULT PREVIEW (rows, columns or text may be truncated):\n"
                            + String(preview.prefix(60_000))
                    }.value
                    try Task.checkCancellation()
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
        guard !processingResult else { return }
        processingResult = true
        let arabic = settings.language == .ar
        let builder = ReportBuilder(engine: vm.engine, arabic: arabic)
        let title = completedCommand
        let sheet = vm.sheet
        let savedPlan = plan, savedNarrative = narrative, savedResult = result
        let workspace = library.workspace
        Task { @MainActor in
            defer { processingResult = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    var markdown = "# \(title)\n\n\(sheet.name) · \(Date().formatted())\n\n"
                    if let savedPlan { markdown += "_\(savedPlan.explanation)_\n\n" }
                    if let savedNarrative { markdown += savedNarrative + "\n\n" }
                    if let savedResult {
                        if savedResult.truncated || savedResult.rows.count > 200 { markdown += "\("analysis.truncated".loc)\n\n" }
                        markdown += builder.markdownTable(savedResult, maxRows: 200)
                    }
                    try workspace.saveReport(sheetID: sheet.id, title: title, body: markdown)
                }.value
                await library.reloadInBackground()
                settings.haptic(.medium)
                dismiss()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func export(_ table: ResultTable, _ format: ExportFormat) {
        guard !processingResult else { return }
        processingResult = true
        Task { @MainActor in
            defer { processingResult = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    switch format {
                    case .xlsx: return try Exporter.xlsx(table: table, name: "SheetX Result")
                    case .json: return try Exporter.json(table: table, name: "SheetX Result")
                    default: return try Exporter.csv(table: table, name: "SheetX Result")
                    }
                }.value
                shareItem = ShareItem(url: url)
            } catch { errorText = error.localizedDescription }
        }
    }
}

private struct AskTextDetail: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
