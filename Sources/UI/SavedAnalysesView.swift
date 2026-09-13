import SwiftUI

struct SavedAnalysesView: View {
    @ObservedObject var vm: SheetViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var analyses: [SavedAnalysis] = []
    @State private var loading = true
    @State private var mutating = false
    @State private var error: String?
    @State private var selected: SavedAnalysis?
    @State private var openNew = false
    @State private var renaming: SavedAnalysis?
    @State private var title = ""
    @State private var showRename = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("analysis.savedHint".loc).font(.subheadline)
                    Text(vm.sheet.name).font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("common.loading".loc) }
                if !loading && analyses.isEmpty {
                    Section {
                        Label("analysis.empty".loc, systemImage: "bookmark")
                        Text("analysis.emptyHint".loc).font(.caption).foregroundStyle(.secondary)
                        Button("ask.title".loc) { openNew = true }
                    }
                }
                Section {
                    ForEach(analyses) { analysis in
                        Button {
                            do {
                                guard let recipe = analysis.recipe else { throw AnalysisError.incompatibleRecipe }
                                try recipe.validate(for: vm.sheet)
                                selected = analysis
                            } catch { self.error = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(analysis.title, systemImage: "bookmark.fill")
                                    .font(.headline).foregroundStyle(.primary)
                                if let recipe = analysis.recipe {
                                    Text(recipe.command).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                } else {
                                    Text("analysis.incompatible".loc).font(.caption).foregroundStyle(.orange)
                                }
                                Text(analysis.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("common.rename".loc) { title = analysis.title; renaming = analysis; showRename = true }
                            Button("common.delete".loc, role: .destructive) { remove(analysis) }
                        }
                        .swipeActions {
                            Button("common.delete".loc, role: .destructive) { remove(analysis) }
                            Button("common.rename".loc) { title = analysis.title; renaming = analysis; showRename = true }.tint(.blue)
                        }
                    }
                } footer: {
                    Text("analysis.latest".loc)
                }
            }
            .disabled(mutating)
            .navigationTitle("analysis.saved".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".loc) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { openNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("ask.title".loc)
                }
            }
            .alert("common.error".loc, isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("common.ok".loc, role: .cancel) {}
                } message: { Text(error ?? "") }
            .alert("common.rename".loc, isPresented: $showRename) {
                    TextField("analysis.name".loc, text: $title)
                    Button("settings.save".loc) { if let entry = renaming { rename(entry) } }
                    Button("common.cancel".loc, role: .cancel) { renaming = nil }
                }
            .sheet(item: $selected, onDismiss: refresh) { entry in
                if let recipe = entry.recipe { AskView(vm: vm, recipe: recipe) }
            }
            .sheet(isPresented: $openNew, onDismiss: refresh) { AskView(vm: vm) }
            .task { await reload() }
        }
    }

    private func refresh() { Task { await reload() } }

    @MainActor
    private func reload() async {
        loading = true
        let sheetID = vm.sheet.id
        let workspace = Workspace.shared
        do {
            let list = try await Task.detached(priority: .userInitiated) {
                try workspace.loadAnalyses(sheetID: sheetID)
            }.value
            try Task.checkCancellation()
            analyses = list
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func rename(_ analysis: SavedAnalysis) {
        let name = title
        renaming = nil
        mutate { try $0.renameAnalysis(id: analysis.id, sheetID: $1, title: name) }
    }

    private func remove(_ analysis: SavedAnalysis) {
        mutate { try $0.deleteAnalysis(id: analysis.id, sheetID: $1) }
    }

    private func mutate(_ operation: @escaping (Workspace, Int64) throws -> Void) {
        guard !mutating else { return }
        mutating = true
        let workspace = Workspace.shared
        let sheetID = vm.sheet.id
        Task { @MainActor in
            defer { mutating = false }
            do {
                try await Task.detached(priority: .userInitiated) { try operation(workspace, sheetID) }.value
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
