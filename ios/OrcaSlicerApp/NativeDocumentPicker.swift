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
        let picker = ImportDocumentPickerController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        if ProcessInfo.processInfo.arguments.contains("--test-document-import"), !settingsOnly {
            picker.testPresentation = {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("orca-document-picker-smoke.txt")
                try? "PASS: native document picker presented".write(to: marker, atomically: true, encoding: .utf8)
                let fixture = StartupRecovery().dataDirectory.deletingLastPathComponent().appendingPathComponent("ios-import-smoke.3mf")
                // A real selection follows the remote service's presentation.
                // Wait one transition in the synthetic picker test too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    context.coordinator.finish(picker, url: fixture)
                }
            }
        }
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        private var finished = false
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func finish(_ controller: UIDocumentPickerViewController, url: URL?) {
            guard !finished else { return }
            finished = true
            let deliver = { [self] in
                // Keep the representable mounted until UIKit and its remote
                // DocumentManager toolbar have completed their dismissal.
                DispatchQueue.main.async { self.completion(url) }
            }
            if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in deliver() }
            } else if controller.presentingViewController != nil {
                controller.dismiss(animated: true, completion: deliver)
            } else {
                deliver()
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, url: urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(controller, url: nil) }
    }
}

private final class ImportDocumentPickerController: UIDocumentPickerViewController {
    var testPresentation: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard view.window != nil, let testPresentation else { return }
        self.testPresentation = nil
        testPresentation()
    }
}
