import Foundation

@main
struct DocumentImportSmoke {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = DocumentImportStore(directory: root.appendingPathComponent("imports"))
        let source = root.appendingPathComponent("model.3mf")
        let bytes = Data("3MF fixture".utf8)
        try bytes.write(to: source)
        let first = try store.copy(source)
        precondition(first != source)
        let original = try Data(contentsOf: source)
        let imported = try Data(contentsOf: first)
        precondition(original == bytes && imported == bytes)
        let same = try store.copy(first)
        precondition(same == first) // Reopening staged files must not delete the source.
        let otherFolder = root.appendingPathComponent("other")
        try fm.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = otherFolder.appendingPathComponent("model.3mf")
        try Data("different file".utf8).write(to: other)
        let second = try store.copy(other)
        precondition(second != first && second.lastPathComponent == first.lastPathComponent)
        let stillOriginal = try Data(contentsOf: first)
        precondition(stillOriginal == bytes)
        do { _ = try store.copy(root.appendingPathComponent("missing.stl")); preconditionFailure("Missing file accepted") }
        catch {}
        do { _ = try store.copy(URL(string: "https://example.invalid/model.stl")!); preconditionFailure("Remote URL accepted as a file") }
        catch {}
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"name":"Whole session","printer_settings_id":"Printer","filament_settings_id":["PLA"],"print_settings_id":"Process"}"#.utf8).write(to: settings)
        let overlay = try DocumentImportStore.isPresetCatalog(settings)
        precondition(!overlay)
        try Data(#"{"name":"PLA","type":"filament","filament_settings_id":["PLA"]}"#.utf8).write(to: settings)
        let filament = try DocumentImportStore.isPresetCatalog(settings)
        precondition(filament)
        let inbox = DocumentInbox()
        for ext in ["orca_printer", "orca_filament", "orca_bundle", "zip", "json"] {
            let source = root.appendingPathComponent("presets." + ext)
            try bytes.write(to: source)
            inbox.receive(source, kind: .model(append: false))
            for _ in 0..<2000 where inbox.receiving > 0 { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let imported = inbox.takeNext(), case .settings = imported.kind else {
                preconditionFailure("Preset bundle was sent to model reader")
            }
            try fm.removeItem(at: imported.url.deletingLastPathComponent())
        }
        print("PASS: JSON and Orca/ZIP bundles route to settings even from Open model")
        print("PASS: coordinated document imports, source preservation, same-name isolation, reopen and failure handling")
    }
}
