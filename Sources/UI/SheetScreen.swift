import SwiftUI

struct SheetScreen: View {
    let sheet: SheetInfo
    @StateObject private var vm: SheetViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteSheet = false
    @State private var deletingSheet = false

    @State private var searchText = ""
    @State private var showFilters = false
    @State private var showColumns = false
    @State private var showAsk = false
    @State private var showDashboard = false
    @State private var showColorHelp = false
    @State private var preparationMode: PreparationMode?
    @State private var showCharts = false
    @State private var showOverview = false
    @State private var showSavedAnalyses = false
    @State private var showStats = false
    @State private var showExport = false
    @State private var showPivot = false
    @State private var showGoTo = false
    @State private var gotoText = ""
    @State private var scrollTarget: Int?
    @State private var selectedColumn: ColumnInfo?
    @State private var shareItem: ShareItem?
    @State private var searchTask: Task<Void, Never>?

    init(sheet: SheetInfo) {
        self.sheet = sheet
        _vm = StateObject(wrappedValue: SheetViewModel(sheet: sheet))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            statusBar
            Divider()
            DataGridView(vm: vm, scrollTarget: $scrollTarget) { row in
                vm.selectedRow = row
            } onHeaderTap: { col in
                selectedColumn = col
            }
        }
        .disabled(deletingSheet)
        .overlay { if deletingSheet { ProgressView("files.deleting".loc).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("files.deleteSheet".loc, isPresented: $confirmDeleteSheet) {
            Button("trash.move".loc, role: .destructive) {
                guard !deletingSheet, !library.storageBusy else { return }
                deletingSheet = true
                searchTask?.cancel()
                vm.suspend()
                Task {
                    let removed = await library.delete(sheet: sheet)
                    deletingSheet = false
                    if removed { dismiss() } else { vm.refresh() }
                }
            }
            Button("common.cancel".loc, role: .cancel) {}
        } message: { Text(String(format: "files.deleteSheetMessage".loc, sheet.name)) }
        .navigationTitle(sheet.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showFilters) {
            FilterEditorView(vm: vm)
        }
        .sheet(isPresented: $showColumns) {
            ColumnManagerView(vm: vm)
        }
        .fullScreenCover(isPresented: $showAsk) {
            AskView(vm: vm)
        }
        .fullScreenCover(item: $preparationMode) { mode in
            if mode == .history { PreparationHistoryView(sheet: sheet) }
            else { PreparationView(sheet: sheet, mode: mode) }
        }
        .sheet(isPresented: $showCharts) {
            ChartsView(vm: vm)
        }
        .sheet(isPresented: $showOverview) { DataOverviewView(vm: vm) }
        .sheet(isPresented: $showSavedAnalyses) { SavedAnalysesView(vm: vm) }
        .onChange(of: settings.showCellColors) { _ in vm.refresh() }
        .fullScreenCover(isPresented: $showDashboard) { DashboardView(sheet: sheet, initialQuery: vm.query) }
        .alert("colors.title".loc, isPresented: $showColorHelp) {
            Button("common.ok".loc, role: .cancel) {}
        } message: { Text("colors.help".loc) }
        .onChange(of: vm.query.search) { value in searchText = value }
        .onChange(of: library.workbooks.flatMap { $0.sheets.map(\.id) }) { ids in
            if !ids.contains(sheet.id) {
                searchTask?.cancel()
                vm.suspend()
                showAsk = false
                dismiss()
            }
        }
        .sheet(isPresented: $showStats) {
            StatsView(vm: vm)
        }
        .sheet(isPresented: $showExport) {
            ExportView(vm: vm)
        }
        .sheet(isPresented: $showPivot) {
            PivotView(vm: vm)
        }
        .sheet(item: $selectedColumn) { col in
            ColumnActionsView(vm: vm, column: col)
        }
        .sheet(isPresented: Binding(get: { vm.selectedRow != nil }, set: { if !$0 { vm.selectedRow = nil } })) {
            if let row = vm.selectedRow {
                RowDetailView(vm: vm, row: row)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("sheet.goto".loc, isPresented: $showGoTo) {
            TextField("1", text: $gotoText).keyboardType(.numberPad)
            Button("common.ok".loc) {
                if let n = Int(gotoText), n > 0 { scrollTarget = min(n, vm.totalRows) - 1 }
            }
            Button("common.cancel".loc, role: .cancel) {}
        }
    }

    // MARK: Bars

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("sheet.search".loc, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onChange(of: searchText) { text in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 320_000_000)
                        guard !Task.isCancelled else { return }
                        vm.setSearch(text)
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    vm.setSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if vm.isLoading {
                ProgressView().controlSize(.mini)
            }
            Text("\(ReportBuilder.formatInt(vm.totalRows)) \("sheet.rows".loc)")
                .font(.caption.bold())
            if vm.query.isActive {
                Text("• \("sheet.filtered".loc)")
                    .font(.caption).foregroundStyle(.orange)
                Button {
                    searchText = ""
                    vm.clearAll()
                } label: {
                    Text("sheet.clear".loc).font(.caption)
                }
            }
            Spacer()
            Button { showGoTo = true } label: {
                Image(systemName: "arrow.down.to.line.compact").font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { settings.haptic(); showAsk = true } label: {
                Image(systemName: "sparkles")
            }
            Menu {
                Button { showDashboard = true } label: { Label("dash.title".loc, systemImage: "rectangle.3.group.fill") }
                Toggle("settings.showColors".loc, isOn: $settings.showCellColors)
                Button { showColorHelp = true } label: { Label("colors.title".loc, systemImage: "paintpalette") }
                Divider()
                Button { preparationMode = .clean } label: { Label("prep.clean".loc, systemImage: "wand.and.stars") }
                    .disabled(library.storageBusy)
                Button { preparationMode = .join } label: { Label("prep.join".loc, systemImage: "link") }
                    .disabled(library.storageBusy)
                Button { preparationMode = .history } label: { Label("prep.history".loc, systemImage: "clock.arrow.circlepath") }
                Divider()
                Button { showOverview = true } label: { Label("overview.title".loc, systemImage: "rectangle.3.group") }
                Button { showSavedAnalyses = true } label: { Label("analysis.saved".loc, systemImage: "bookmark") }
                Divider()
                Button { showPivot = true } label: { Label("sheet.pivot".loc, systemImage: "square.split.2x2") }
                Button { showFilters = true } label: { Label("sheet.filters".loc, systemImage: "line.3.horizontal.decrease.circle") }
                Button { showColumns = true } label: { Label("sheet.columns".loc, systemImage: "list.bullet.indent") }
                Button { showStats = true } label: { Label("sheet.stats".loc, systemImage: "chart.bar.doc.horizontal") }
                Button { showCharts = true } label: { Label("sheet.chart".loc, systemImage: "chart.pie") }
                Divider()
                Button { showExport = true } label: { Label("sheet.export".loc, systemImage: "square.and.arrow.up") }
                Button { generateReport() } label: { Label("report.generate".loc, systemImage: "doc.text.magnifyingglass") }
                Divider()
                Button(role: .destructive) { confirmDeleteSheet = true } label: {
                    Label("files.deleteSheet".loc, systemImage: "trash")
                }.disabled(library.storageBusy || deletingSheet)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func generateReport() {
        let builder = ReportBuilder(engine: vm.engine, arabic: settings.language == .ar)
        let query = vm.query
        let sheetID = sheet.id
        let name = sheet.name
        Task.detached(priority: .userInitiated) {
            do {
                let md = try builder.fullReport(query: query)
                await MainActor.run {
                    library.saveReport(sheetID: sheetID, title: name, body: md)
                    settings.haptic(.medium)
                }
            } catch {
                await MainActor.run { library.errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Row detail

struct RowDetailView: View {
    @ObservedObject var vm: SheetViewModel
    let row: [DBValue]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.sheet.columns) { col in
                    let value = col.index + 1 < row.count ? row[col.index + 1] : DBValue.null
                    VStack(alignment: .leading, spacing: 4) {
                        Text(col.name).font(.caption).foregroundStyle(.secondary)
                        Text(value.stringValue.isEmpty ? "—" : value.stringValue)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = value.stringValue
                        } label: { Label("sheet.copy".loc, systemImage: "doc.on.doc") }
                    }
                }
            }
            .navigationTitle("sheet.details".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".loc) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let text = vm.sheet.columns.map { col -> String in
                            let v = col.index + 1 < row.count ? row[col.index + 1] : DBValue.null
                            return "\(col.name): \(v.stringValue)"
                        }.joined(separator: "\n")
                        UIPasteboard.general.string = text
                    } label: { Image(systemName: "doc.on.doc") }
                }
            }
        }
    }
}

// MARK: - Share helpers

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
