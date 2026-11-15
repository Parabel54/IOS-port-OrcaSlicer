import Foundation

@main
struct DocumentImportSmoke {
    static func main() throws {
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
        print("PASS: coordinated document imports, source preservation, same-name isolation, reopen and failure handling")
    }
}
