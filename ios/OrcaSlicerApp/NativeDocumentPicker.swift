import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NativeDocumentPicker: UIViewControllerRepresentable {
    let settingsOnly: Bool
    let onPick: (URL) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some providers assign dynamic UTIs to STL/3MF. Allow files here and
        // validate extensions after selection instead of greying out valid models.
        let picker = ImportDocumentPickerController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onDismiss: () -> Void
        private var finished = false
        init(onPick: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.onDismiss = onDismiss
        }

        func finish(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }
            finished = true
            let deliver = { [self] in
                // Keep the representable mounted until UIKit and its remote
                // DocumentManager toolbar have completed their dismissal.
                DispatchQueue.main.async { self.onDismiss() }
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
            // Acquire access and start staging before UIKit revokes the provider grant.
            if let url = urls.first { onPick(url) }
            finish(controller)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(controller) }
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
