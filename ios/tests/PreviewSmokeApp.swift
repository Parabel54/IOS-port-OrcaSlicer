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
        let checks: [(String, () -> Bool)] = [
            ("camera", { PlateSceneView.cameraSmokeTest(includePreview: false) }),
            ("progressive_ranges", GCodePathGeometry.progressiveCursorSmokeTest),
            ("progressive_gpu", GCodePathGeometry.progressiveGPUSmokeTest),
            ("preview_geometry", { GCodePathGeometry.previewSmokeTest(includeProgressive: false) })
        ]
        var results: [String: Bool] = [:]
        for (name, check) in checks {
            let passed = check()
            results[name] = passed
            NSLog("%@: %@", passed ? "PASS" : "FAIL", name)
        }
        let receipt: [String: Any] = [
            "source": ProcessInfo.processInfo.environment["ORCA_GRAPHICS_SOURCE"] ?? "unknown",
            "tests": results,
            "passed": results.values.allSatisfy { $0 },
            "scope": "SceneKit camera, geometry and GPU; no slicing engine or full-app UI"
        ]
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-renderer.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        } catch { NSLog("Cannot write graphics test receipt: %@", error.localizedDescription) }
    }
}
