import UIKit

// A simulator-only harness for the real SceneKit code. It does not link the
// slicing engine, import a model, authenticate, or replace full app validation.
@main
final class PreviewSmokeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.runChecks() }
        return true
    }

    private func runChecks() {
        var diagnostics: [String: String] = [:]
        let checks: [(String, () -> Bool)] = [
            ("camera", { PlateSceneView.cameraSmokeTest(includePreview: false, includePaint: false,
                onFailure: { diagnostics["camera"] = $0 }) }),
            ("painted_filaments_gpu", PlateSceneView.filamentPaintSmokeTest),
            ("progressive_ranges", GCodePathGeometry.progressiveCursorSmokeTest),
            ("progressive_gpu", GCodePathGeometry.progressiveGPUSmokeTest),
            ("preview_geometry", { GCodePathGeometry.previewSmokeTest(includeProgressive: false) })
        ]
        var results: [String: Bool] = [:]
        for (name, check) in checks {
            results[name] = check()
            NSLog("%@: %@", results[name] == true ? "PASS" : "FAIL", name)
            writeReceipt(results, diagnostics: diagnostics, completed: false)
        }
        writeReceipt(results, diagnostics: diagnostics, completed: true)
    }

    private func writeReceipt(_ results: [String: Bool], diagnostics: [String: String], completed: Bool) {
        let receipt: [String: Any] = [
            "source": ProcessInfo.processInfo.environment["ORCA_GRAPHICS_SOURCE"] ?? "unknown",
            "tests": results, "diagnostics": diagnostics, "completed": completed,
            "passed": completed && results.values.allSatisfy { $0 },
            "scope": "SceneKit camera, geometry and GPU; no slicing engine or full-app UI"
        ]
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-renderer.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        } catch { NSLog("Cannot write graphics test receipt: %@", error.localizedDescription) }
    }
}
