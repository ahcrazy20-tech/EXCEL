import Foundation

@MainActor
final class PreparationViewModel: ObservableObject {
    @Published private(set) var preview: PreparationPreview?
    @Published private(set) var busy = false
    @Published private(set) var publishing = false
    @Published var message: String?
    @Published var saved: WorkbookInfo?
    private var cancellation: QueryCancellation?

    func invalidate() { preview = nil; message = nil; saved = nil }
    func cancel() { cancellation?.cancel() }

    func run(_ recipe: PreparationRecipe, path: String) {
        guard !busy else { return }
        invalidate(); busy = true
        let token = QueryCancellation(); cancellation = token
        Task {
            defer { busy = false; cancellation = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PreparationEngine.prepare(recipe, workspacePath: path, cancellation: token)
                }.value
                guard !token.isCancelled else { throw CancellationError() }
                preview = result
            } catch is CancellationError { message = "prep.cancelled".loc }
            catch { message = error.localizedDescription }
        }
    }

    func save(name: String, duplicates: Bool, invalid: Bool, library: Library) {
        guard !busy, let preview else { return }
        busy = true; publishing = true; message = nil
        let token = QueryCancellation(); cancellation = token
        Task {
            defer { busy = false; publishing = false; cancellation = nil }
            do {
                // A committed result is success even if Cancel was tapped just after commit.
                saved = try await library.publish(preview, name: name, duplicates: duplicates, invalid: invalid, cancellation: token)
                self.preview = nil
            } catch is CancellationError { message = "prep.cancelled".loc }
            catch { message = error.localizedDescription }
        }
    }
}
