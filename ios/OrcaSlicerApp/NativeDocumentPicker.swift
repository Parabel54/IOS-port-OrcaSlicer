import SwiftUI
import UniformTypeIdentifiers
import UIKit

// Dynamic SwiftUI menus containing sharing actions exposed nested, unhittable
// accessibility elements in the compact workspace. UIKit owns this tap target
// and its menu, including VoiceOver activation and iPad sharing anchors.
struct NativeProjectMenu: UIViewRepresentable {
    let makeMenu: (UIButton) -> UIMenu
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "folder"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.isAccessibilityElement = true
        button.accessibilityLabel = "File and project actions"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.isEnabled = isEnabled
        button.menu = makeMenu(button)
    }

    static func share(_ url: URL, from source: UIView?) {
        DispatchQueue.main.async { [weak source] in
            let window = source?.window ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            guard var presenter = window?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            guard let anchor = source ?? presenter.viewIfLoaded else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = anchor
            activity.popoverPresentationController?.sourceRect = source?.bounds ??
                CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
            if source == nil { activity.popoverPresentationController?.permittedArrowDirections = [] }
            presenter.present(activity, animated: true)
        }
    }
}

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
