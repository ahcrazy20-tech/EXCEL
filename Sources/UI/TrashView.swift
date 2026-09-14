import SwiftUI

struct TrashView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TrashedSheet] = []
    @State private var total = 0
    @State private var page = 0
    @State private var loading = true
    @State private var working = false
    @State private var message: String?
    @State private var selected: TrashedSheet?
    @State private var generation = 0
    private let pageSize = 50

    var body: some View {
        NavigationStack {
            List {
                Section { Text("trash.hint".loc).font(.subheadline) }
                if let message { Section { Text(message).foregroundStyle(.orange).textSelection(.enabled) } }
                if loading { ProgressView("common.loading".loc) }
                if !loading && entries.isEmpty {
                    Section { Label("trash.empty".loc, systemImage: "trash") }
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.headline).lineLimit(3)
                        Text(entry.workbookName).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("\(ReportBuilder.formatInt(entry.rowCount)) \("sheet.rows".loc) · \(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { act(entry, permanently: false) } label: {
                                Label("trash.restore".loc, systemImage: "arrow.uturn.backward")
                            }
                            .accessibilityIdentifier("trash.restore.\(entry.sheetID)")
                            Spacer()
                            Button(role: .destructive) { selected = entry } label: {
                                Image(systemName: "trash.slash").frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("trash.permanent".loc + " " + entry.name)
                        }.buttonStyle(.borderless).disabled(working || loading || library.storageBusy)
                    }.padding(.vertical, 4)
                }
                if total > pageSize {
                    Section {
                        HStack {
                            Button("result.previous".loc) { page = max(0, page - 1); Task { await load() } }.disabled(page == 0)
                            Spacer()
                            Text("\(page + 1) / \(max(1, (total + pageSize - 1) / pageSize))").monospacedDigit()
                            Spacer()
                            Button("result.next".loc) { page += 1; Task { await load() } }.disabled((page + 1) * pageSize >= total)
                        }.disabled(loading || working)
                    }
                }
                Section { Text("trash.storageHint".loc).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("trash.title".loc + " (\(total))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() }.disabled(working) }
            }
            .safeAreaInset(edge: .bottom) {
                if working { ProgressView("trash.working".loc).padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            }
            .refreshable { await load() }
            .task(id: library.trashedCount) { await load() }
            .alert("trash.permanent".loc, isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), presenting: selected) { entry in
                Button("trash.permanent".loc, role: .destructive) { act(entry, permanently: true) }
                Button("common.cancel".loc, role: .cancel) {}
            } message: { entry in Text(String(format: "trash.permanentMessage".loc, entry.name)) }
        }
        .interactiveDismissDisabled(working)
    }

    private func load() async {
        generation += 1
        let version = generation, workspace = library.workspace, requested = page
        loading = true
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let count = try workspace.trashCount()
                let page = min(requested, max(0, (count - 1) / 50))
                return (count, page, try workspace.loadTrash(offset: page * 50))
            }.value
            guard version == generation, !Task.isCancelled else { return }
            total = result.0; page = result.1; entries = result.2
        } catch {
            if version == generation { message = error.localizedDescription }
        }
        if version == generation { loading = false }
    }

    private func act(_ entry: TrashedSheet, permanently: Bool) {
        guard !working, !library.storageBusy else { return }
        working = true; message = nil; selected = nil
        Task {
            let success = await library.recoverOrPurge(entry, permanently: permanently)
            message = library.errorMessage ?? (success ? (permanently ? "trash.deleted".loc : "trash.restored".loc) : "trash.stale".loc)
            library.errorMessage = nil
            working = false
            await load()
        }
    }
}
