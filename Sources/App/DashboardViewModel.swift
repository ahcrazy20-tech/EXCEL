import Foundation
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    let sheet: SheetInfo
    let path: String
    @Published var recipe: DashboardRecipe { didSet { dirty = true; snapshot = nil } }
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var loading = true
    @Published var dirty = false
    @Published var message: String?
    private var generation = 0
    private var cancellation: QueryCancellation?

    init(sheet: SheetInfo, path: String, query: QuerySpec) {
        self.sheet = sheet; self.path = path
        recipe = .starter(sheet: sheet, query: query)
    }

    func load(workspace: Workspace) async {
        do {
            let id = sheet.id
            let saved = try await Task.detached { try workspace.dashboard(sheetID: id) }.value
            try Task.checkCancellation()
            if let saved {
                try saved.validate(for: sheet)
                recipe = saved
            }
            dirty = false; loading = false
            refresh()
        } catch { if !Task.isCancelled { message = error.localizedDescription }; loading = false }
    }

    func cancel() { cancellation?.cancel() }
    func stop() { generation += 1; cancellation?.cancel(); busy = false }

    func refresh() {
        cancellation?.cancel(); generation += 1
        let version = generation, token = QueryCancellation()
        cancellation = token; busy = true; message = nil; snapshot = nil
        let recipe = self.recipe, path = self.path, sheet = self.sheet
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DashboardRunner.run(recipe, sheet: sheet, path: path, cancellation: token)
                }.value
                guard version == generation else { return }
                if token.isCancelled { throw CancellationError() }
                snapshot = result
            } catch {
                guard version == generation else { return }
                message = error is CancellationError ? "dash.cancelled".loc : error.localizedDescription
            }
            if version == generation { busy = false; cancellation = nil }
        }
    }

    func select(column: Int, value: DBValue) {
        guard !busy else { return }
        recipe.selection = DashboardSelection(column: column, value: value)
        refresh()
    }

    func save(library: Library) async {
        let savedRecipe = recipe
        do {
            try await library.saveDashboard(savedRecipe, sheet: sheet)
            if recipe == savedRecipe { dirty = false }
            message = "dash.saved".loc
        } catch { message = error.localizedDescription }
    }
}
