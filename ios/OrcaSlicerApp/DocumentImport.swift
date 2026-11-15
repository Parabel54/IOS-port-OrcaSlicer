import Foundation
import Combine

enum DocumentImportKind {
    case automatic
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
    static let models = DocumentImportStore(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OrcaSlicer/Imports", isDirectory: true))
    static let temporary = DocumentImportStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("OrcaSlicer/ImportStaging", isDirectory: true))

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
        receiving += 1
        Task {
            defer { receiving -= 1 }
            do {
                let extensionName = url.pathExtension.lowercased()
                guard ["stl", "obj", "3mf", "amf", "json"].contains(extensionName) else {
                    errorMessage = String(localized: "Choose an STL, OBJ, 3MF, AMF model or a JSON settings file.")
                    return
                }
                let resolved: DocumentImportKind
                switch kind {
                case .automatic: resolved = extensionName == "json" ? .settings(preset: nil) : .model(append: false)
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
