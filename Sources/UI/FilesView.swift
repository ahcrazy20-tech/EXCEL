import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var showImporter = false
    @State private var searchText = ""

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
                    .disabled(library.importing)
                }
            }
            .searchable(text: $searchText)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Library.supportedTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    library.importFiles(urls, headerRow: settings.headerRowDefault)
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            .overlay(alignment: .bottom) {
                if library.importing { importBanner }
            }
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
            Toggle("files.headerRow".loc, isOn: $settings.headerRowDefault)
                .padding(.horizontal, 44)
                .padding(.top, 6)
        }
        .padding()
    }

    private var list: some View {
        List {
            Section {
                Toggle("files.headerRow".loc, isOn: $settings.headerRowDefault)
                    .font(.subheadline)
            }
            ForEach(filtered) { wb in
                Section {
                    ForEach(wb.sheets) { sheet in
                        NavigationLink {
                            SheetScreen(sheet: sheet)
                        } label: {
                            SheetRow(sheet: sheet)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                library.delete(workbook: wb)
                            } label: {
                                Label("files.delete".loc, systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "doc.fill").foregroundStyle(.tint)
                        Text(wb.name).font(.subheadline.bold())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: wb.sizeBytes, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                } footer: {
                    Text("\(ReportBuilder.formatInt(wb.totalRows)) \("files.rows".loc) • \(wb.sheets.count) \("files.sheets".loc)")
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { library.reload() }
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
