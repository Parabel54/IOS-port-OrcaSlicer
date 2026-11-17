import Foundation

/// Recovery is checked before constructing the C++ engine. A process abort or jetsam
/// cannot be caught by Swift; a durable marker makes the next launch recoverable.
struct StartupRecovery {
    let defaults: UserDefaults
    let dataDirectory: URL
    let revision: String
    private let pendingKey = "orca.ios.startup.pending"
    private var stamp: URL { dataDirectory.appendingPathComponent(".ios-system-profiles-revision") }

    init(defaults: UserDefaults = .standard, dataDirectory: URL? = nil, revision: String? = nil) {
        self.defaults = defaults
        self.dataDirectory = dataDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrcaSlicer", isDirectory: true)
        self.revision = revision ?? (Bundle.main.object(forInfoDictionaryKey: "OrcaProfileRevision") as? String ?? "unversioned")
    }

    var interrupted: Bool { defaults.bool(forKey: pendingKey) }

    func begin() {
        defaults.set(true, forKey: pendingKey)
        // Persist before entering native code, which may terminate the process.
        defaults.synchronize()
    }

    func finish() {
        defaults.removeObject(forKey: pendingKey)
        defaults.synchronize()
    }

    /// Only the generated system tree is replaced. Projects, plates, user_presets,
    /// connection metadata and Keychain items are never reset by this operation.
    func prepareProfiles(rebuild: Bool = false) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let system = dataDirectory.appendingPathComponent("system", isDirectory: true)
        let recorded = try? String(contentsOf: stamp, encoding: .utf8)
        if !rebuild, recorded == revision, fm.fileExists(atPath: system.path) { return }
        if fm.fileExists(atPath: system.path) {
            let backups = dataDirectory.appendingPathComponent("Recovered system profiles", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            try fm.moveItem(at: system, to: backups.appendingPathComponent(UUID().uuidString, isDirectory: true))
        }
        if fm.fileExists(atPath: stamp.path) { try fm.removeItem(at: stamp) }
    }

    func profilesLoaded() throws {
        try revision.write(to: stamp, atomically: true, encoding: .utf8)
    }
}
