import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeDocumentPicker: UIViewControllerRepresentable {
    let settingsOnly: Bool
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some providers assign dynamic UTIs to STL/3MF. Allow files here and
        // validate extensions after selection instead of greying out valid models.
        let picker = ImportDocumentPickerController(forOpeningContentTypes: settingsOnly ? [.json] : [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        if ProcessInfo.processInfo.arguments.contains("--test-document-import"), !settingsOnly {
            picker.testPresentation = { [weak picker] in
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("orca-document-picker-smoke.txt")
                try? "PASS: native document picker presented".write(to: marker, atomically: true, encoding: .utf8)
                let fixture = StartupRecovery().dataDirectory.deletingLastPathComponent().appendingPathComponent("ios-import-smoke.3mf")
                picker?.dismiss(animated: false) { context.coordinator.completion(fixture) }
            }
        }
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}

private final class ImportDocumentPickerController: UIDocumentPickerViewController {
    var testPresentation: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard presentingViewController != nil, let testPresentation else { return }
        self.testPresentation = nil
        testPresentation()
    }
}
