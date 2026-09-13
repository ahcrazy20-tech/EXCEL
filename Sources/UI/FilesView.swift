import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var pendingDeletion: LibraryDeletion?

    var filtered: [WorkbookInfo] {
        guard !searchText.isEmpty else { return library.workbooks }
        return library.workbooks.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.workbooks.isEmpty && !library.importing {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("files.title".loc)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        settings.haptic()
                        showImporter = true
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .disabled(library.storageBusy)
                }
            }
            .searchable(text: $searchText)
            .sheet(isPresented: $showImporter) {
                DocumentPicker { urls in
                    showImporter = false
                    library.importFiles(urls, headerMode: settings.headerMode)
                }
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom) {
                if library.importing { importBanner }
                else if library.deleting {
                    ProgressView("files.deleting".loc).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .alert("files.confirmDelete".loc, isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                   presenting: pendingDeletion) { target in
                Button("common.delete".loc, role: .destructive) {
                    Task {
                        switch target {
                        case .sheet(let sheet): _ = await library.delete(sheet: sheet)
                        case .workbook(let workbook): _ = await library.delete(workbook: workbook)
                        }
                    }
                }
                Button("common.cancel".loc, role: .cancel) {}
            } message: { target in Text(target.message) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("files.empty.title".loc).font(.title2.bold())
            Text("files.empty.body".loc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            VStack(spacing: 10) {
                Button {
                    showImporter = true
                } label: {
                    Label("files.import".loc, systemImage: "square.and.arrow.down")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("files.sample".loc) { library.createSampleData() }
                    .buttonStyle(.bordered)
            }
            headerModePicker
                .padding(.horizontal, 44)
                .padding(.top, 6)
        }
        .padding()
    }

    private var headerModePicker: some View {
        VStack(spacing: 4) {
            Picker("files.headerMode".loc, selection: Binding(
                get: { settings.headerMode },
                set: { settings.headerMode = $0 })) {
                ForEach(HeaderMode.allCases) { mode in
                    Text(mode.display).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("files.headerMode.hint".loc)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var list: some View {
        List {
            Section {
                headerModePicker
                    .font(.subheadline)
            } footer: {
                Text("files.headerMode.hint".loc).font(.caption2)
            }
            ForEach(filtered) { wb in
                Section {
                    ForEach(wb.sheets) { sheet in
                        NavigationLink {
                            SheetScreen(sheet: sheet)
                        } label: {
                            SheetRow(sheet: sheet)
                        }
                        .accessibilityIdentifier("files.sheet.\(sheet.id)")
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDeletion = .sheet(sheet) } label: {
                                Label("files.deleteSheet".loc, systemImage: "trash")
                            }.disabled(library.storageBusy)
                        }
                        .contextMenu {
                            Button(role: .destructive) { pendingDeletion = .sheet(sheet) } label: {
                                Label("files.deleteSheet".loc, systemImage: "trash")
                            }.disabled(library.storageBusy)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "doc.fill").foregroundStyle(.tint)
                        Text(wb.name).font(.subheadline.bold())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: wb.sizeBytes, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                        Menu {
                            Button(role: .destructive) { pendingDeletion = .workbook(wb) } label: {
                                Label("files.deleteWorkbook".loc, systemImage: "trash")
                            }.disabled(library.storageBusy)
                        } label: { Image(systemName: "ellipsis.circle").padding(6) }
                            .accessibilityLabel("files.workbookActions".loc)
                    }
                    .textCase(nil)
                } footer: {
                    Text("\(ReportBuilder.formatInt(wb.totalRows)) \("files.rows".loc) • \(wb.sheets.count) \("files.sheets".loc)")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { if !library.storageBusy { library.reload() } }
    }

    private var importBanner: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(library.progress?.stage ?? "files.importing".loc)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Button("common.cancel".loc) { library.cancelImport() }
                    .font(.caption)
            }
            if let p = library.progress {
                if p.fraction >= 0 {
                    ProgressView(value: min(max(p.fraction, 0), 1))
                } else {
                    ProgressView()
                }
                Text("\(ReportBuilder.formatInt(p.rowsDone)) \("files.rows".loc)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8, y: 3)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

struct SheetRow: View {
    let sheet: SheetInfo

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: "tablecells")
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(sheet.name).font(.body.weight(.medium)).lineLimit(1)
                Text("\(ReportBuilder.formatInt(sheet.rowCount)) \("files.rows".loc) × \(sheet.columns.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The confirmation states both the target and the extent of deletion.
private enum LibraryDeletion {
    case sheet(SheetInfo)
    case workbook(WorkbookInfo)

    var message: String {
        switch self {
        case .sheet(let sheet):
            return String(format: "files.deleteSheetMessage".loc, sheet.name)
        case .workbook(let workbook):
            return String(format: "files.deleteWorkbookMessage".loc, workbook.name, workbook.sheets.count)
        }
    }
}
