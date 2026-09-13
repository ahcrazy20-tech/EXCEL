import SwiftUI

enum PreparationMode: String, Identifiable {
    case clean, join, history
    var id: String { rawValue }
    var title: String { "prep.\(rawValue)".loc }
}

struct PreparationView: View {
    let sheet: SheetInfo
    let mode: PreparationMode
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PreparationViewModel()
    @State private var draft: CleaningDraft
    @State private var editing: CleaningStep?
    @State private var rightID: Int64
    @State private var leftKey: Int
    @State private var rightKey: Int
    @State private var joinMode: JoinMode
    @State private var keyMode: JoinKeyMode
    @State private var rightColumns: Set<Int>
    @State private var outputName: String
    @State private var duplicates = false
    @State private var invalid = false
    private let originalSource: PreparationSource
    private let savedRightSource: PreparationSource?

    init(sheet: SheetInfo, mode: PreparationMode, recipe: PreparationRecipe? = nil) {
        self.sheet = sheet; self.mode = mode
        var steps: [CleaningStep] = [], join: JoinRecipe?
        var source = PreparationSource(sheet)
        if case .clean(let clean) = recipe?.operation { steps = clean.steps; source = clean.source }
        if case .join(let saved) = recipe?.operation { join = saved; source = saved.left }
        originalSource = source; savedRightSource = join?.right
        _draft = State(initialValue: CleaningDraft(steps: steps))
        _rightID = State(initialValue: join?.right.id ?? sheet.id)
        _leftKey = State(initialValue: join?.leftKey ?? 0)
        _rightKey = State(initialValue: join?.rightKey ?? 0)
        _joinMode = State(initialValue: join?.mode ?? .left)
        _keyMode = State(initialValue: join?.keyMode ?? .exact)
        _rightColumns = State(initialValue: Set(join?.rightColumns ?? sheet.columns.map(\.index)))
        _outputName = State(initialValue: String(sheet.name.prefix(90)) + " — " + mode.title)
    }

    private var rightSheet: SheetInfo? { library.workbooks.flatMap(\.sheets).first { $0.id == rightID } }
    private var rightSource: PreparationSource? {
        if let savedRightSource, savedRightSource.id == rightID { return savedRightSource }
        return rightSheet.map(PreparationSource.init)
    }
    private var recipe: PreparationRecipe? {
        if mode == .clean { return PreparationRecipe(operation: .clean(CleaningRecipe(source: originalSource, steps: draft.steps))) }
        guard let right = rightSource else { return nil }
        return PreparationRecipe(operation: .join(JoinRecipe(left: originalSource, right: right, leftKey: leftKey,
            rightKey: rightKey, mode: joinMode, keyMode: keyMode, rightColumns: rightColumns.sorted())))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("prep.immutable".loc, systemImage: "lock.shield")
                    Text("prep.valuesOnly".loc).font(.caption).foregroundStyle(.secondary)
                    Text("prep.limits".loc).font(.caption).foregroundStyle(.secondary)
                    Text(originalSource.name).font(.headline).lineLimit(3)
                }
                Group {
                    if mode == .clean { cleaningEditor } else { joinEditor }
                    Section("prep.outputName".loc) {
                        TextField("prep.outputName".loc, text: $outputName).accessibilityIdentifier("prep.outputName")
                    }
                }.disabled(model.busy)
                if let message = model.message { Section { Text(message).foregroundStyle(.orange).textSelection(.enabled) } }
                if let saved = model.saved {
                    Section {
                        Label("prep.saved".loc, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(saved.name)
                        if let result = saved.sheets.first {
                            NavigationLink("prep.open".loc) { SheetScreen(sheet: result) }
                        }
                    }
                }
                if let preview = model.preview {
                    PreparationSummaryView(summary: preview.summary)
                    if let reason = preview.blockReason { Section { Text(reason).foregroundStyle(.red) } }
                    Section {
                        Text("prep.sampleHint".loc).font(.caption).foregroundStyle(.secondary)
                        if let before = preview.before {
                            Text("prep.before".loc).font(.headline)
                            ResultTableView(table: before)
                        }
                        Text("prep.after".loc).font(.headline)
                        ResultTableView(table: preview.after)
                    }
                    if let rejected = preview.rejected {
                        Section("prep.rejected".loc) { ResultTableView(table: rejected) }
                    }
                    if preview.artifact != nil {
                        Section("prep.review".loc) {
                            if preview.needsDuplicateApproval { Toggle("prep.approveDuplicates".loc, isOn: $duplicates) }
                            if preview.needsInvalidApproval { Toggle("prep.approveInvalid".loc, isOn: $invalid) }
                            Text("prep.newOutput".loc).font(.caption).foregroundStyle(.secondary)
                        }.disabled(model.busy)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.busy ? "common.cancel".loc : "common.close".loc) {
                        if model.busy { model.cancel() } else { dismiss() }
                    }.accessibilityIdentifier("prep.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .interactiveDismissDisabled(model.busy)
        .sheet(item: $editing) { step in
            CleaningStepEditor(step: step, columns: originalSource.columns) { updated in
                var steps = draft.steps
                if let index = steps.firstIndex(where: { $0.id == updated.id }) { steps[index] = updated }
                else if steps.count < 20 { steps.append(updated) }
                draft.replace(with: steps)
            }
        }
        .onChange(of: recipe) { _ in model.invalidate(); duplicates = false; invalid = false }
        .onDisappear { model.cancel() }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if model.busy {
                HStack { ProgressView(); Text(model.publishing ? "prep.saving".loc : "prep.running".loc).font(.caption); Spacer() }
            }
            HStack {
                Button("prep.preview".loc) {
                    duplicates = false; invalid = false
                    if let recipe { model.run(recipe, path: library.workspace.db.path) }
                }
                .buttonStyle(.bordered).disabled(model.busy || recipe == nil || library.storageBusy)
                .accessibilityIdentifier("prep.preview")
                Spacer(minLength: 8)
                Button("prep.save".loc) { model.save(name: outputName, duplicates: duplicates, invalid: invalid, library: library) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier("prep.save")
            }
        }
        .padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
    }

    private var canSave: Bool {
        guard !model.busy, !library.storageBusy, let preview = model.preview, preview.artifact != nil else { return false }
        return (!preview.needsDuplicateApproval || duplicates) && (!preview.needsInvalidApproval || invalid)
            && !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && outputName.count <= 120
    }

    @ViewBuilder private var cleaningEditor: some View {
        Section("prep.recipe".loc) {
            Text("prep.undoHint".loc).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { draft.undo() } label: { Label("prep.undo".loc, systemImage: "arrow.uturn.backward") }
                    .disabled(!draft.canUndo).accessibilityIdentifier("prep.undo")
                Spacer()
                Button { draft.redo() } label: { Label("prep.redo".loc, systemImage: "arrow.uturn.forward") }
                    .disabled(!draft.canRedo).accessibilityIdentifier("prep.redo")
            }.buttonStyle(.borderless)
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    Button { editing = step } label: {
                        Text("\(index + 1). \(step.operation.title)").font(.headline)
                    }.buttonStyle(.borderless)
                    if step.operation.needsColumn, originalSource.columns.indices.contains(step.column) {
                        Text(originalSource.columns[step.column].name).font(.caption).lineLimit(2)
                    }
                    HStack {
                        Button { move(index, -1) } label: { Label("prep.up".loc, systemImage: "arrow.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Label("prep.down".loc, systemImage: "arrow.down") }.disabled(index + 1 >= draft.steps.count)
                        Spacer()
                        Button(role: .destructive) {
                            var steps = draft.steps; steps.remove(at: index); draft.replace(with: steps)
                        } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("common.delete".loc)
                    }.buttonStyle(.borderless)
                }
            }
            Button { editing = CleaningStep(operation: .trim) } label: { Label("prep.addStep".loc, systemImage: "plus.circle") }
                .disabled(draft.steps.count >= 20).accessibilityIdentifier("prep.addStep")
        }
    }

    private func move(_ index: Int, _ offset: Int) {
        var steps = draft.steps; steps.swapAt(index, index + offset); draft.replace(with: steps)
    }

    @ViewBuilder private var joinEditor: some View {
        Section("prep.joinSources".loc) {
            Picker("prep.leftKey".loc, selection: $leftKey) {
                ForEach(originalSource.columns, id: \.index) { Text($0.name).tag($0.index) }
            }
            Picker("prep.rightSheet".loc, selection: $rightID) {
                ForEach(library.workbooks) { workbook in
                    ForEach(workbook.sheets) { sheet in Text("\(workbook.name) / \(sheet.name)").tag(sheet.id) }
                }
            }.onChange(of: rightID) { _ in
                rightKey = 0; rightColumns = Set(rightSource?.columns.map(\.index) ?? [])
            }
            if let rightSource {
                Picker("prep.rightKey".loc, selection: $rightKey) {
                    ForEach(rightSource.columns, id: \.index) { Text($0.name).tag($0.index) }
                }
            }
            Picker("prep.joinMode".loc, selection: $joinMode) { ForEach(JoinMode.allCases) { Text($0.title).tag($0) } }
            Picker("prep.keyMode".loc, selection: $keyMode) { ForEach(JoinKeyMode.allCases) { Text($0.title).tag($0) } }
            Text("prep.joinHint".loc).font(.caption).foregroundStyle(.secondary)
            Text(keyMode == .exact ? "prep.exactHint".loc : "prep.normalizedHint".loc).font(.caption).foregroundStyle(.secondary)
        }
        Section("prep.rightColumns".loc) {
            if let rightSource {
                ForEach(rightSource.columns, id: \.index) { column in
                    Toggle(column.name, isOn: Binding(get: { rightColumns.contains(column.index) }, set: { on in
                        if on { rightColumns.insert(column.index) } else { rightColumns.remove(column.index) }
                    }))
                }
            }
        }
    }
}

private struct CleaningStepEditor: View {
    @State var step: CleaningStep
    let columns: [AnalysisColumnSignature]
    let save: (CleaningStep) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("prep.operation".loc, selection: $step.operation) {
                    ForEach(CleaningOperation.allCases) { Text($0.title).tag($0) }
                }
                if step.operation.needsColumn {
                    Picker("prep.column".loc, selection: $step.column) {
                        ForEach(columns, id: \.index) { Text($0.name).tag($0.index) }
                    }
                }
                if step.operation == .replaceText {
                    TextField("prep.find".loc, text: $step.value)
                    TextField("prep.replace".loc, text: $step.replacement)
                    Text("prep.literalHint".loc).font(.caption)
                }
                if step.operation == .fillMissing {
                    TextField("prep.fillValue".loc, text: $step.value)
                    Text("prep.fillHint".loc).font(.caption)
                }
                if step.operation == .parseNumber {
                    Picker("prep.numberFormat".loc, selection: $step.numberConvention) {
                        ForEach(NumberConvention.allCases) { Text($0.title).tag($0) }
                    }
                    Text("prep.numberHint".loc).font(.caption)
                }
                if step.operation == .parseDate {
                    Picker("prep.dateFormat".loc, selection: $step.dateFormat) {
                        ForEach(PreparationDateFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("prep.dateHint".loc).font(.caption)
                }
                Text("prep.missingHint".loc).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("prep.editStep".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel".loc) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("sheet.apply".loc) { save(step); dismiss() }
                        .disabled((step.operation == .replaceText && step.value.isEmpty) || step.value.count > 1000 || step.replacement.count > 1000)
                }
            }
        }
    }
}

struct PreparationSummaryView: View {
    let summary: PreparationSummary
    var body: some View {
        Section("prep.summary".loc) {
            metric("prep.outputRows", summary.outputRows)
            if let join = summary.join {
                metric("prep.leftRows", join.leftRows); metric("prep.rightRows", join.rightRows)
                metric("prep.matchedLeft", join.matchedLeft); metric("prep.unmatchedLeft", join.unmatchedLeft)
                metric("prep.unmatchedRight", join.unmatchedRight)
                metric("prep.blankLeft", join.blankLeftKeys); metric("prep.blankRight", join.blankRightKeys)
                metric("prep.duplicateLeft", join.duplicateLeftKeys); metric("prep.duplicateRight", join.duplicateRightKeys)
            }
            ForEach(summary.cleaning) { impact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(impact.operation.title + (impact.columnName.isEmpty ? "" : " · " + impact.columnName)).font(.headline)
                    metric("prep.changed", impact.changed); metric("prep.removed", impact.removed)
                    metric("prep.invalid", impact.invalid)
                }
            }
        }
    }
    private func metric(_ key: String, _ value: Int) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(key.loc); Spacer(); Text(ReportBuilder.formatInt(value)).monospacedDigit() }.font(.subheadline)
    }
}

struct PreparationHistoryView: View {
    let sheet: SheetInfo
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var record: PreparationRecord?
    @State private var error: String?
    @State private var loaded = false
    @State private var rebuild = false

    var body: some View {
        NavigationStack {
            Form {
                Section { Text("prep.historyHint".loc).font(.subheadline) }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                if !loaded { ProgressView() }
                if let record {
                    Section {
                        Text(record.createdAt, style: .date)
                        if let recipe = record.recipe {
                            ForEach(Array(recipe.sources.enumerated()), id: \.offset) { _, source in
                                Text(source.name).font(.headline)
                                Text("ID \(source.id) · \(source.rowCount) \("sheet.rows".loc)").font(.caption)
                            }
                            Button("prep.rebuild".loc) { rebuild = true }.disabled(!valid(recipe))
                            if !valid(recipe) { Text("prep.error.recipe".loc) }
                        } else { Text("prep.error.recipe".loc) }
                    }
                    if let summary = record.summary { PreparationSummaryView(summary: summary) }
                } else if loaded && error == nil { Section { Text("prep.noHistory".loc) } }
            }
            .navigationTitle("prep.history".loc).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() } } }
        }
        .task {
            let workspace = library.workspace
            do { record = try await Task.detached { try workspace.preparation(sheetID: sheet.id) }.value }
            catch { self.error = error.localizedDescription }
            loaded = true
        }
        .fullScreenCover(isPresented: $rebuild) {
            if let recipe = record?.recipe {
                PreparationView(sheet: sheet, mode: recipeMode(recipe), recipe: recipe)
            }
        }
    }
    private func valid(_ recipe: PreparationRecipe) -> Bool {
        do { try recipe.validate(); return true } catch { return false }
    }
    private func recipeMode(_ recipe: PreparationRecipe) -> PreparationMode {
        if case .clean = recipe.operation { return .clean }; return .join
    }
}
