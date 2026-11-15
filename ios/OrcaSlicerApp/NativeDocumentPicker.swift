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
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ProcessInfo.processInfo.arguments.contains("--test-native-picker") {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("orca-document-picker-smoke.txt")
            try? "PASS: native document picker presented".write(to: marker, atomically: true, encoding: .utf8)
        }
    }
}
