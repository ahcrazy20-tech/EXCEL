import SwiftUI

// MARK: - Filters

struct FilterEditorView: View {
    @ObservedObject var vm: SheetViewModel
    @Environment(\.dismiss) var dismiss
    @State private var draft = QuerySpec()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $draft.join) {
                        Text("sheet.matchAll".loc).tag(FilterJoin.and)
                        Text("sheet.matchAny".loc).tag(FilterJoin.or)
                    }
                    .pickerStyle(.segmented)
                }

                Section("sheet.filters".loc) {
                    ForEach($draft.filters) { $filter in
                        FilterRowEditor(columns: vm.sheet.columns, filter: $filter)
                    }
                    .onDelete { draft.filters.remove(atOffsets: $0) }

                    Button {
                        draft.filters.append(FilterCondition(columnIndex: vm.sheet.columns.first?.index ?? 0))
                    } label: {
                        Label("sheet.addFilter".loc, systemImage: "plus.circle")
                    }
                }

                Section("sheet.sort".loc) {
                    ForEach($draft.sorts) { $sort in
                        HStack {
                            Picker("", selection: $sort.columnIndex) {
                                ForEach(vm.sheet.columns) { c in Text(c.name).tag(c.index) }
                            }
                            .labelsHidden()
                            Spacer()
                            Button {
                                sort.ascending.toggle()
                            } label: {
                                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .onDelete { draft.sorts.remove(atOffsets: $0) }

                    Button {
                        draft.sorts.append(SortSpec(columnIndex: vm.sheet.columns.first?.index ?? 0))
                    } label: {
                        Label("sheet.sort".loc, systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .navigationTitle("sheet.filters".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".loc) { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("sheet.clear".loc) {
                        draft = QuerySpec()
                        vm.apply(query: draft)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("sheet.apply".loc) {
                        var q = draft
                        q.search = vm.query.search
                        for f in q.filters { vm.engine.ensureIndex(columnIndex: f.columnIndex) }
                        vm.apply(query: q)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = vm.query }
        }
    }
}

struct FilterRowEditor: View {
    let columns: [ColumnInfo]
    @Binding var filter: FilterCondition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $filter.columnIndex) {
                    ForEach(columns) { c in Text(c.name).tag(c.index) }
                }
                .labelsHidden()
                Picker("", selection: $filter.op) {
                    ForEach(FilterOperator.allCases) { op in Text(op.display).tag(op) }
                }
                .labelsHidden()
            }
            if filter.op.needsValue {
                HStack {
                    TextField("common.value".loc, text: $filter.value)
                        .textFieldStyle(.roundedBorder)
                    if filter.op.needsSecondValue {
                        TextField("…", text: $filter.value2)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Column manager

struct ColumnManagerView: View {
    @ObservedObject var vm: SheetViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("common.all".loc) { vm.hiddenColumns.removeAll() }
                    Button("common.none".loc) {
                        vm.hiddenColumns = Set(vm.sheet.columns.dropFirst().map { $0.index })
                    }
                }
                ForEach(vm.sheet.columns) { col in
                    HStack {
                        Image(systemName: col.kind.symbol).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(col.name)
                            Text(col.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !vm.hiddenColumns.contains(col.index) },
                            set: { on in
                                if on { vm.hiddenColumns.remove(col.index) } else { vm.hiddenColumns.insert(col.index) }
                            }))
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("sheet.columns".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("common.done".loc) { dismiss() } }
            }
        }
    }
}

// MARK: - Column actions (tap on a header)

struct ColumnActionsView: View {
    @ObservedObject var vm: SheetViewModel
    let column: ColumnInfo
    @Environment(\.dismiss) var dismiss
    @State private var stats: QueryEngine.ColumnStats?
    @State private var distinct: [String] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        vm.query.sorts = [SortSpec(columnIndex: column.index, ascending: true)]
                        vm.engine.ensureIndex(columnIndex: column.index)
                        vm.refresh(); dismiss()
                    } label: { Label("A → Z", systemImage: "arrow.up") }
                    Button {
                        vm.query.sorts = [SortSpec(columnIndex: column.index, ascending: false)]
                        vm.engine.ensureIndex(columnIndex: column.index)
                        vm.refresh(); dismiss()
                    } label: { Label("Z → A", systemImage: "arrow.down") }
                    Button {
                        vm.hiddenColumns.insert(column.index); dismiss()
                    } label: { Label("sheet.hide".loc, systemImage: "eye.slash") }
                    Button {
                        vm.engine.ensureIndex(columnIndex: column.index); dismiss()
                    } label: { Label("sheet.index".loc, systemImage: "bolt") }
                }

                if let s = stats {
                    Section("sheet.stats".loc) {
                        statRow("Filled", ReportBuilder.formatInt(s.nonEmpty))
                        statRow("Empty", ReportBuilder.formatInt(max(0, s.total - s.nonEmpty)))
                        statRow("Distinct", ReportBuilder.formatInt(s.distinct))
                        if let v = s.sum { statRow("Sum", ReportBuilder.formatNumber(v)) }
                        if let v = s.avg { statRow("Average", ReportBuilder.formatNumber(v)) }
                        if let v = s.median { statRow("Median", ReportBuilder.formatNumber(v)) }
                        if let v = s.stdev { statRow("Std dev", ReportBuilder.formatNumber(v)) }
                        if let v = s.min { statRow("Min", v.stringValue) }
                        if let v = s.max { statRow("Max", v.stringValue) }
                    }
                    if !s.topValues.isEmpty {
                        Section("Top values") {
                            ForEach(s.topValues.prefix(10), id: \.0) { value, count in
                                Button {
                                    vm.query.filters.append(FilterCondition(columnIndex: column.index, op: .equals, value: value))
                                    vm.refresh(); dismiss()
                                } label: {
                                    HStack {
                                        Text(value).lineLimit(1)
                                        Spacer()
                                        Text(ReportBuilder.formatInt(count)).foregroundStyle(.secondary).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                } else if loading {
                    Section { HStack { ProgressView(); Text("common.loading".loc) } }
                }

                if !distinct.isEmpty {
                    Section("Filter by value") {
                        ForEach(distinct.prefix(60), id: \.self) { v in
                            Button(v) {
                                vm.query.filters.append(FilterCondition(columnIndex: column.index, op: .equals, value: v))
                                vm.refresh(); dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(column.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("common.close".loc) { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func load() async {
        let engine = vm.engine
        let index = column.index
        let query = vm.query
        let result: (QueryEngine.ColumnStats?, [String]) = await Task.detached(priority: .userInitiated) {
            let s = try? engine.stats(for: index, query: query, includeTop: true)
            let d = (try? engine.distinctValues(columnIndex: index, limit: 200)) ?? []
            return (s, d)
        }.value
        stats = result.0
        distinct = result.1.count > 1 && result.1.count <= 200 ? result.1 : []
        loading = false
    }
}
