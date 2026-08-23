import SwiftUI
import UniformTypeIdentifiers

/// UIKit document picker wrapped for SwiftUI.
///
/// We use this instead of SwiftUI's `.fileImporter` because `fileImporter`
/// silently drops its completion callback in several situations (view
/// refreshes, sideloaded / unsigned builds where security-scoped resource
/// access fails, etc.). `UIDocumentPickerViewController` with `asCopy: true`
/// copies the picked files straight into the app sandbox, so no
/// security-scoped access is needed at all — it just works.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Library.supportedTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let dismiss: () -> Void

        init(onPick: @escaping ([URL]) -> Void, dismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            dismiss()
            guard !urls.isEmpty else { return }
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}
