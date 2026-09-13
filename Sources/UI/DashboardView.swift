import SwiftUI
import Charts

struct DashboardView: View {
    let sheet: SheetInfo
    @StateObject private var model: DashboardViewModel
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DashboardCard?
    @State private var filtering = false
    @State private var renaming = false
    @State private var name = ""
    @State private var presenting = false
    @State private var saving = false
    @State private var confirmClose = false
    @State private var confirmReset = false

    init(sheet: SheetInfo, initialQuery: QuerySpec = QuerySpec()) {
        self.sheet = sheet
        _model = StateObject(wrappedValue: DashboardViewModel(sheet: sheet, path: Workspace.shared.db.path, query: initialQuery))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    intro
                    if let message = model.message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                    if let snapshot = model.snapshot {
                        ForEach(model.recipe.cards) { card in
                            if let result = snapshot.cards.first(where: { $0.id == card.id }) {
                                DashboardCardView(card: card, table: result.table, selecting: !model.busy) { value in
                                    model.select(column: card.groupColumn, value: value)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if !presenting {
                                        Menu {
                                            Button("dash.editCard".loc) { editing = card }
                                            Button("prep.up".loc) { move(card, -1) }
                                            Button("prep.down".loc) { move(card, 1) }
                                            Button("common.delete".loc, role: .destructive) {
                                                model.recipe.cards.removeAll { $0.id == card.id }; model.refresh()
                                            }.disabled(model.recipe.cards.count == 1)
                                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                                        .accessibilityLabel("dash.editCard".loc + " " + card.title)
                                    }
                                }
                            }
                        }
                    } else if !model.busy && !model.loading {
                        // Keep recipe editing available even when a card/query fails.
                        ForEach(model.recipe.cards) { card in
                            Button { editing = card } label: { Label(card.title, systemImage: "slider.horizontal.3") }
                                .buttonStyle(.bordered)
                        }
                    }
                    if model.busy || model.loading { ProgressView("common.loading".loc).frame(maxWidth: .infinity).padding() }
                }
                .padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .navigationTitle(model.recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) {
                        if model.dirty { confirmClose = true } else { dismiss() }
                    }.disabled(saving)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("sheet.filters".loc) { filtering = true }
                        Button("dash.addCard".loc) { editing = DashboardCard(title: "dash.rows".loc) }
                            .disabled(model.recipe.cards.count >= 12)
                        Button("common.rename".loc) { name = model.recipe.title; renaming = true }
                        Button(presenting ? "dash.editMode".loc : "dash.present".loc) { presenting.toggle() }
                        Button("dash.reset".loc, role: .destructive) { confirmReset = true }
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .disabled(model.loading || model.busy || saving)
                    .accessibilityLabel("dash.options".loc)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(model.busy ? "common.cancel".loc : "dash.refresh".loc) {
                        if model.busy { model.cancel() } else { model.refresh() }
                    }.buttonStyle(.bordered).disabled(model.loading || saving)
                        .accessibilityIdentifier("dash.refresh")
                    Spacer()
                    Button("settings.save".loc) {
                        saving = true
                        Task { await model.save(library: library); saving = false }
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.loading || model.busy || saving || library.storageBusy)
                        .accessibilityIdentifier("dash.save")
                }.padding(12).background(.regularMaterial)
            }
        }
        .interactiveDismissDisabled(model.dirty || saving)
        .task { await model.load(workspace: library.workspace) }
        .onDisappear { model.stop() }
        .sheet(item: $editing) { card in
            DashboardCardEditor(card: card, sheet: sheet) { changed in
                if let i = model.recipe.cards.firstIndex(where: { $0.id == changed.id }) { model.recipe.cards[i] = changed }
                else if model.recipe.cards.count < 12 { model.recipe.cards.append(changed) }
                model.refresh()
            }
        }
        .sheet(isPresented: $filtering) {
            DashboardFiltersView(query: model.recipe.query, sheet: sheet) { query in
                model.recipe.query = query; model.recipe.selection = nil; model.refresh()
            }
        }
        .alert("common.rename".loc, isPresented: $renaming) {
            TextField("dash.name".loc, text: $name)
            Button("sheet.apply".loc) { model.recipe.title = name; model.refresh() }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120)
            Button("common.cancel".loc, role: .cancel) {}
        }
        .alert("dash.unsaved".loc, isPresented: $confirmClose) {
            Button("dash.discard".loc, role: .destructive) { dismiss() }
            Button("common.cancel".loc, role: .cancel) {}
        } message: { Text("dash.unsavedHint".loc) }
        .alert("dash.reset".loc, isPresented: $confirmReset) {
            Button("dash.reset".loc, role: .destructive) { model.recipe = .starter(sheet: sheet); model.refresh() }
            Button("common.cancel".loc, role: .cancel) {}
        } message: { Text("dash.resetHint".loc) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sheet.name).font(.headline)
            if let snapshot = model.snapshot {
                Text("\(ReportBuilder.formatInt(snapshot.matchingRows)) \("dash.matching".loc) · \(snapshot.completedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !presenting { Text("dash.hint".loc).font(.caption).foregroundStyle(.secondary) }
            if model.dirty { Text("dash.unsaved".loc).font(.caption).foregroundStyle(.orange) }
            if !model.recipe.query.filters.isEmpty || !model.recipe.query.search.isEmpty {
                Button("dash.sharedFilters".loc + " (\(model.recipe.query.filters.count))") { filtering = true }
                    .disabled(model.busy || saving)
            }
            if let selection = model.recipe.selection {
                HStack {
                    Text((sheet.columns.indices.contains(selection.column) ? sheet.columns[selection.column].name : "?") + ": " + DashboardCardView.label(selection.value)).lineLimit(2)
                    Spacer()
                    Button("sheet.clear".loc) { model.recipe.selection = nil; model.refresh() }
                        .disabled(model.busy || saving)
                }.font(.caption).padding(8).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func move(_ card: DashboardCard, _ offset: Int) {
        guard let i = model.recipe.cards.firstIndex(where: { $0.id == card.id }), model.recipe.cards.indices.contains(i + offset) else { return }
        model.recipe.cards.swapAt(i, i + offset); model.refresh()
    }
}

private struct DashboardCardView: View {
    let card: DashboardCard
    let table: ResultTable
    let selecting: Bool
    let select: (DBValue) -> Void

    static func label(_ value: DBValue) -> String {
        if case .null = value { return "(NULL)" }
        if case .text(let text) = value, text.isEmpty { return "(\("dash.empty".loc))" }
        if case .double(let number) = value { return String(number) }
        return value.stringValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.title).font(.headline).lineLimit(3).padding(.trailing, 32)
            if card.display == .kpi {
                let value = table.rows.first?.first ?? .null
                Text(value == .null ? "—" : Self.label(value))
                    .font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(2)
                    .accessibilityLabel(card.title + ": " + (value == .null ? "dash.noNumeric".loc : Self.label(value)))
            } else if card.display == .table {
                ResultTableView(table: table)
            } else {
                chart.frame(height: 220).clipped()
                Text(card.display == .bar ? "dash.barHint".loc : "dash.lineHint".loc).font(.caption).foregroundStyle(.secondary)
                // Exact typed category values are retained; labels are never used as query strings.
                DisclosureGroup("dash.selectGroup".loc) {
                    ForEach(table.rows.indices, id: \.self) { index in
                        let row = table.rows[index]
                        Button { select(row[0]) } label: {
                            HStack {
                                Text(Self.label(row[0])).lineLimit(2)
                                Spacer()
                                Text(row[1] == .null ? "—" : Self.label(row[1])).monospacedDigit()
                            }
                        }.disabled(!selecting || row[0].stringValue.utf8.count > 4096)
                        .padding(.vertical, 4)
                    }
                }
                if table.rows.isEmpty { Text("sheet.noResults".loc).foregroundStyle(.secondary) }
            }
            if table.truncated { Text("dash.truncated".loc).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var chart: some View {
        Chart {
            ForEach(table.rows.indices, id: \.self) { index in
                if let value = table.rows[index][1].doubleValue, value.isFinite {
                    if card.display == .bar {
                        BarMark(x: .value("Group", index), y: .value(card.metric.title, value))
                            .foregroundStyle(Color.accentColor.gradient)
                            .accessibilityLabel(Self.label(table.rows[index][0]))
                            .accessibilityValue(Self.label(table.rows[index][1]))
                    } else {
                        LineMark(x: .value("Group", index), y: .value(card.metric.title, value))
                        PointMark(x: .value("Group", index), y: .value(card.metric.title, value))
                            .accessibilityLabel(Self.label(table.rows[index][0]))
                            .accessibilityValue(Self.label(table.rows[index][1]))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: Array(table.rows.indices)) { axis in
                AxisValueLabel {
                    if let index = axis.as(Int.self), table.rows.indices.contains(index) {
                        Text(String(Self.label(table.rows[index][0]).prefix(16))).font(.caption2).lineLimit(1)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        let plot = geometry[proxy.plotAreaFrame]
                        guard selecting, plot.contains(event.location),
                              let coordinate: Double = proxy.value(atX: event.location.x - plot.minX) else { return }
                        let index = Int(coordinate.rounded())
                        guard table.rows.indices.contains(index), table.rows[index][0].stringValue.utf8.count <= 4096 else { return }
                        select(table.rows[index][0])
                    })
            }
        }
    }
}

private struct DashboardCardEditor: View {
    @State var card: DashboardCard
    let sheet: SheetInfo
    let save: (DashboardCard) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("dash.name".loc, text: $card.title)
                Picker("dash.cardType".loc, selection: $card.display) {
                    ForEach(DashboardDisplay.allCases) { Text($0.title).tag($0) }
                }
                if card.display != .table {
                    Picker("dash.metric".loc, selection: $card.metric) { ForEach(DashboardMetric.allCases) { Text($0.title).tag($0) } }
                    if card.metric.needsColumn {
                        Picker("prep.column".loc, selection: $card.valueColumn) { ForEach(sheet.columns) { Text($0.name).tag($0.index) } }
                    }
                    if card.display == .bar || card.display == .line {
                        Picker("dash.group".loc, selection: $card.groupColumn) { ForEach(sheet.columns) { Text($0.name).tag($0.index) } }
                    }
                }
                Text("dash.numericHint".loc).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("dash.editCard".loc).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel".loc) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("sheet.apply".loc) { save(card); dismiss() }
                        .disabled(card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || card.title.count > 120)
                }
            }
        }
    }
}

private struct DashboardFiltersView: View {
    @State var query: QuerySpec
    let sheet: SheetInfo
    let save: (QuerySpec) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("sheet.search".loc, text: $query.search)
                Picker("sheet.filters".loc, selection: $query.join) {
                    Text("sheet.matchAll".loc).tag(FilterJoin.and)
                    Text("sheet.matchAny".loc).tag(FilterJoin.or)
                }.pickerStyle(.segmented)
                ForEach($query.filters) { $filter in
                    VStack {
                        FilterRowEditor(columns: sheet.columns, filter: $filter, operators: FilterOperator.allCases.filter { $0 != .regex })
                        Button("common.delete".loc, role: .destructive) { query.filters.removeAll { $0.id == filter.id } }
                    }
                }
                Button("sheet.addFilter".loc) { query.filters.append(FilterCondition(columnIndex: 0)) }.disabled(query.filters.count >= 16)
                Text("dash.filterHint".loc).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("sheet.filters".loc).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel".loc) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("sheet.apply".loc) { save(query); dismiss() } }
                ToolbarItem(placement: .bottomBar) { Button("sheet.clear".loc) { save(QuerySpec()); dismiss() } }
            }
        }
    }
}

struct DashboardsView: View {
    @EnvironmentObject private var library: Library
    @State private var saved: [StoredDashboard] = []
    @State private var selected: SheetInfo?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("dash.libraryHint".loc).font(.subheadline) }
                if let message { Text(message).foregroundStyle(.orange) }
                ForEach(library.workbooks) { workbook in
                    Section(workbook.name) {
                        ForEach(workbook.sheets) { sheet in
                            Button { selected = sheet } label: {
                                Label(saved.first(where: { $0.id == sheet.id })?.title ?? sheet.name,
                                      systemImage: saved.contains(where: { $0.id == sheet.id }) ? "rectangle.3.group.fill" : "plus.rectangle")
                            }
                        }
                    }
                }
                if library.workbooks.isEmpty { Text("files.empty.title".loc) }
            }
            .navigationTitle("dash.title".loc)
            .task { await load() }
            .refreshable { await load() }
            .fullScreenCover(item: $selected, onDismiss: { Task { await load() } }) { DashboardView(sheet: $0) }
        }
    }
    private func load() async {
        let workspace = library.workspace
        do { saved = try await Task.detached { try workspace.loadDashboards() }.value }
        catch { message = error.localizedDescription }
    }
}
