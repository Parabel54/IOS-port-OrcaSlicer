import Foundation
import Combine

enum DocumentImportKind {
    case automatic
    case toolpath
    case model(append: Bool)
    case settings(preset: Int?)
}

struct DocumentImportRequest: Identifiable {
    let id = UUID()
    let kind: DocumentImportKind
    var isSettings: Bool {
        if case .settings = kind { return true }
        return false
    }
}

struct ImportedDocument: Identifiable {
    let id = UUID()
    let url: URL
    let kind: DocumentImportKind
}

struct DocumentImportStore {
    let directory: URL
    static let toolpathExtensions: Set<String> = ["gcode", "gco", "g"]
    static let models = DocumentImportStore(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OrcaSlicer/Imports", isDirectory: true))
    static let temporary = DocumentImportStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("OrcaSlicer/ImportStaging", isDirectory: true))

    static func isPresetCatalog(_ url: URL) throws -> Bool {
        if ["orca_printer", "orca_filament", "orca_bundle", "zip"].contains(url.pathExtension.lowercased()) { return true }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        if object?["type"] != nil { return true }
        let identities = ["printer_settings_id", "filament_settings_id", "print_settings_id"]
        return identities.filter { object?[$0] != nil }.count == 1
    }

    func owns(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// File-provider URLs may be placeholders or security-scoped. Coordinate the
    /// actual read while access is held, and never overwrite the source by name.
    func copy(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        if owns(source), FileManager.default.fileExists(atPath: source.path) { return source }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = false
        defer { if !copied { try? FileManager.default.removeItem(at: folder) } }
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                guard try readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try FileManager.default.copyItem(at: readable, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get()
        copied = true
        return destination
    }
}

@MainActor
final class DocumentInbox: ObservableObject {
    @Published private(set) var pending: [ImportedDocument] = []
    @Published var errorMessage = ""
    @Published private(set) var receiving = 0

    func receive(_ url: URL, kind: DocumentImportKind = .automatic) {
        // Hold provider access before dismissing the picker; staging continues
        // asynchronously after its delegate has returned.
        let accessed = url.startAccessingSecurityScopedResource()
        receiving += 1
        Task {
            defer {
                receiving -= 1
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let extensionName = url.pathExtension.lowercased()
                guard ["stl", "obj", "3mf", "amf", "json", "orca_printer", "orca_filament", "orca_bundle", "zip"].contains(extensionName) || DocumentImportStore.toolpathExtensions.contains(extensionName) else {
                    errorMessage = String(localized: "Choose a model, G-code, JSON settings file, or Orca preset bundle.")
                    return
                }
                if case .settings = kind, !["json", "orca_printer", "orca_filament", "orca_bundle", "zip"].contains(extensionName) {
                    errorMessage = String(localized: "Choose JSON settings or an Orca preset bundle.")
                    return
                }
                let resolved: DocumentImportKind
                switch kind {
                case .automatic where DocumentImportStore.toolpathExtensions.contains(extensionName): resolved = .toolpath
                case .model where DocumentImportStore.toolpathExtensions.contains(extensionName): resolved = .toolpath
                case .automatic: resolved = ["json", "orca_printer", "orca_filament", "orca_bundle", "zip"].contains(extensionName) ? .settings(preset: nil) : .model(append: false)
                case .model where ["json", "orca_printer", "orca_filament", "orca_bundle", "zip"].contains(extensionName): resolved = .settings(preset: nil)
                default: resolved = kind
                }
                let local = try await Task.detached(priority: .userInitiated) {
                    try DocumentImportStore.models.copy(url)
                }.value
                pending.append(ImportedDocument(url: local, kind: resolved))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func takeNext() -> ImportedDocument? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
}
