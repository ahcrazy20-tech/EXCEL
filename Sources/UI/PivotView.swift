import SwiftUI

/// Cross-tabulation builder: rows × columns × value, computed by SQLite's GROUP BY
/// so it works on millions of rows in one pass. Tapping a cell filters the sheet.
struct PivotView: View {
    @ObservedObject var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    @State private var rowDim1: Int = 0
    @State private var rowDim2: Int? = nil
    @State private var colDim: Int? = nil
    @State private var function: AggFunction = .count
    @State private var valueColumn: Int? = nil
    @State private var rowLimit: Int = 100
    @State private var result: QueryEngine.PivotResult?
    @State private var loading = false
    @State private var shareItem: ShareItem?

    private let functions: [AggFunction] = [.count, .sum, .avg, .min, .max]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if loading {
                    Spacer()
                    ProgressView("common.loading".loc)
                    Spacer()
                } else if let result {
                    matrix(result)
                } else {
                    hintView
                }
            }
            .navigationTitle("sheet.pivot".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        settings.haptic()
                        run()
                    } label: {
                        Label("pivot.run".loc, systemImage: "arrow.forward.circle.fill")
                    }
                    .disabled(loading)
                }
            }
            .onAppear(perform: pickDefaults)
            .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                dimensionMenu("pivot.rows".loc, selection: $rowDim1, optional: false)
                dimensionMenu("pivot.rows2".loc, selection: $rowDim2, optional: true)
            }
            HStack(spacing: 8) {
                dimensionMenu("pivot.columns".loc, selection: $colDim, optional: true)
                metricMenu
            }
            HStack(spacing: 8) {
                Picker("pivot.limit".loc, selection: $rowLimit) {
                    ForEach([50, 100, 200, 500], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                if result != nil {
                    Button {
                        shareCSV()
                    } label: {
                        Label("pivot.csv".loc, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A compact menu that picks one column (or "none" when optional).
    private func dimensionMenu(_ title: String, selection: Binding<Int?>, optional: Bool) -> some View {
        Menu {
            if optional {
                Button("pivot.none".loc) { selection.wrappedValue = nil }
            }
            ForEach(vm.sheet.columns) { col in
                Button("\(col.symbolMarker) \(col.name)") {
                    selection.wrappedValue = col.index
                }
            }
        } label: {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(selectedLabel(selection.wrappedValue))
                    .font(.caption.bold()).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func dimensionMenu(_ title: String, selection: Binding<Int>, optional: Bool) -> some View {
        let optionalBinding = Binding<Int?>(
            get: { selection.wrappedValue },
            set: { selection.wrappedValue = $0 ?? 0 })
        return dimensionMenu(title, selection: optionalBinding, optional: optional)
    }

    private var metricMenu: some View {
        Menu {
            ForEach(functions) { f in
                Button(f.display) { function = f }
            }
            Divider()
            ForEach(vm.sheet.columns) { col in
                Button("\(col.symbolMarker) \(col.name)") { valueColumn = col.index }
            }
        } label: {
            HStack {
                Text("pivot.metric".loc).font(.caption2).foregroundStyle(.secondary)
                Text(metricLabel)
                    .font(.caption.bold()).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var metricLabel: String {
        guard function != .count, let v = valueColumn,
              v >= 0, v < vm.sheet.columns.count else { return function.display }
        return "\(function.display) (\(vm.sheet.columns[v].name))"
    }

    private func selectedLabel(_ idx: Int?) -> String {
        guard let idx, idx >= 0, idx < vm.sheet.columns.count else { return "pivot.none".loc }
        return vm.sheet.columns[idx].name
    }

    // MARK: Matrix

    private func matrix(_ r: QueryEngine.PivotResult) -> some View {
        VStack(spacing: 0) {
            if r.groupCapReached {
                Text("pivot.cap".loc)
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.vertical, 4)
            }
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(spacing: 0) {
                    headerRow(r)
                    ForEach(Array(r.rowKeys.enumerated()), id: \.offset) { ri, keys in
                        matrixRow(r, rowIndex: ri, keys: keys)
                    }
                    totalsRow(r)
                }
            }
        }
    }

    private func headerRow(_ r: QueryEngine.PivotResult) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(r.rowDimNames.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            ForEach(Array(r.columnKeys.enumerated()), id: \.offset) { _, key in
                Text(key.isEmpty ? r.metricName : key)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 96, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
            Text("pivot.total".loc)
                .font(.caption.bold())
                .frame(width: 96, alignment: .trailing)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    private func matrixRow(_ r: QueryEngine.PivotResult, rowIndex: Int, keys: [String]) -> some View {
        let rowMax = max(r.rowTotals[rowIndex], 0.000001)
        return HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key.isEmpty ? "—" : key)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            ForEach(Array(r.cells[rowIndex].enumerated()), id: \.offset) { ci, value in
                Button {
                    settings.haptic()
                    applyCellFilter(r, rowIndex: rowIndex, colIndex: ci)
                } label: {
                    Text(value.map { ReportBuilder.formatNumber($0) } ?? "—")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                        .padding(.horizontal, 6)
                        .background(heat(value ?? 0, over: rowMax))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(ReportBuilder.formatNumber(r.rowTotals[rowIndex]))
                .font(.caption.monospacedDigit().bold())
                .frame(width: 96, alignment: .trailing)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color(uiColor: .separator)), alignment: .bottom)
    }

    private func totalsRow(_ r: QueryEngine.PivotResult) -> some View {
        HStack(spacing: 0) {
            Text("pivot.total".loc)
                .font(.caption.bold())
                .frame(width: 130 * CGFloat(max(1, r.rowDimNames.count)), alignment: .leading)
                .padding(.horizontal, 6)
            ForEach(Array(r.columnTotals.enumerated()), id: \.offset) { _, total in
                Text(ReportBuilder.formatNumber(total))
                    .font(.caption.monospacedDigit().bold())
                    .frame(width: 96, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
            Text(ReportBuilder.formatNumber(r.grandTotal))
                .font(.caption.monospacedDigit().bold())
                .frame(width: 96, alignment: .trailing)
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func heat(_ value: Double, over maximum: Double) -> Color {
        guard value > 0, maximum > 0 else { return Color.clear }
        let ratio = max(0, min(1, value / maximum))
        return Color.accentColor.opacity(0.06 + 0.32 * ratio)
    }

    private var hintView: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.split.2x2")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("sheet.pivot".loc).font(.headline)
            Text("pivot.hint".loc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func pickDefaults() {
        let columns = vm.sheet.columns
        if let first = columns.first(where: { $0.kind == .text }) ?? columns.first {
            rowDim1 = first.index
        }
        if let numeric = columns.first(where: { $0.kind == .number }) {
            valueColumn = numeric.index
            function = .sum
        }
    }

    private func run() {
        loading = true
        let spec = QueryEngine.PivotSpec(
            rowColumns: [rowDim1, rowDim2].compactMap { $0 },
            columnDim: colDim,
            valueColumn: function == .count ? nil : valueColumn,
            function: function,
            query: vm.query,
            rowLimit: rowLimit)
        let engine = vm.engine
        Task.detached(priority: .userInitiated) {
            let r = try? engine.runPivot(spec)
            await MainActor.run {
                result = r
                loading = false
            }
        }
    }

    /// Tapping a matrix cell filters the sheet down to that row × column slice.
    private func applyCellFilter(_ r: QueryEngine.PivotResult, rowIndex: Int, colIndex: Int) {
        guard colIndex < r.columnKeys.count,
              r.cells[rowIndex][colIndex] != nil else { return }
        var query = vm.query
        var filters = query.filters
        let rowDims = [rowDim1, rowDim2].compactMap { $0 }
        for (i, dim) in rowDims.enumerated() {
            let label = r.rowKeys[rowIndex][min(i, r.rowKeys[rowIndex].count - 1)]
            filters.append(FilterCondition(columnIndex: dim, op: .equals, value: label, value2: ""))
        }
        if let cd = colDim, colIndex < r.columnKeys.count {
            filters.append(FilterCondition(columnIndex: cd, op: .equals, value: r.columnKeys[colIndex], value2: ""))
        }
        guard !filters.isEmpty else { return }
        query.filters = filters
        query.join = .and
        vm.apply(query: query)
        dismiss()
    }

    private func shareCSV() {
        guard let r = result else { return }
        var columns = r.rowDimNames
        columns += r.columnKeys.map { $0.isEmpty ? r.metricName : $0 }
        columns += ["pivot.total".loc]
        var rows: [[DBValue]] = []
        for (i, keys) in r.rowKeys.enumerated() {
            var row: [DBValue] = keys.map { .text($0) }
            row += r.cells[i].map { v in v.map { DBValue.double($0) } ?? .null }
            row.append(.double(r.rowTotals[i]))
            rows.append(row)
        }
        var totalRow: [DBValue] = Array(repeating: .null, count: r.rowDimNames.count)
        totalRow += r.columnTotals.map { .double($0) }
        totalRow.append(.double(r.grandTotal))
        rows.append(totalRow)
        let table = ResultTable(columns: columns, rows: rows, truncated: false)
        if let url = try? Exporter.csv(table: table, name: "\(vm.sheet.name) — pivot") {
            shareItem = ShareItem(url: url)
        }
    }
}

private extension ColumnInfo {
    /// Small type marker shown inside the dimension menus.
    var symbolMarker: String {
        switch kind {
        case .number: return "#"
        case .date: return "📅"
        case .boolean: return "✓"
        case .text: return "≡"
        }
    }
}
