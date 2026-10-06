#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Picks files the way the LX source import does. SwiftUI's `fileImporter` did not open for some users, and some Files.app
/// providers hand back a security-scoped URL that cannot be read once the sheet is gone. `UIDocumentPickerViewController` with
/// `asCopy: true` copies the chosen files into the app's temporary folder first, so every provider gives a plain local file.
/// Present it in a `.sheet`; the sheet closes itself when files are picked or the picker is cancelled.
struct CopyingDocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.item]
    var allowsMultipleSelection = false
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onPick(urls)
        }
    }
}
#endif
