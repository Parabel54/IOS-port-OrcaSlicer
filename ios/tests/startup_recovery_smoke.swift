import Foundation

@main
struct StartupRecoverySmoke {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let domain = "OrcaStartupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = StartupRecovery(defaults: defaults, dataDirectory: directory, revision: "v1")
        precondition(!first.interrupted)
        first.begin()
        precondition(StartupRecovery(defaults: defaults, dataDirectory: directory).interrupted)
        first.finish()
        precondition(!first.interrupted)

        let system = directory.appendingPathComponent("system")
        let user = directory.appendingPathComponent("user_presets/process")
        let plates = directory.appendingPathComponent("plates")
        for path in [system, user, plates] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data("desktop cache".utf8).write(to: system.appendingPathComponent("old.opc"))
        let preset = user.appendingPathComponent("custom.json")
        let project = plates.appendingPathComponent("plate.3mf")
        try Data("user preset".utf8).write(to: preset)
        try Data("project".utf8).write(to: project)
        defaults.set("connection metadata", forKey: "orca.ios.printer-connections.v1")
        try first.prepareProfiles()
        precondition(!fm.fileExists(atPath: system.path))
        let backups = directory.appendingPathComponent("Recovered system profiles")
        let backup = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)[0]
        precondition(fm.fileExists(atPath: backup.appendingPathComponent("old.opc").path))
        let savedPreset = try Data(contentsOf: preset)
        precondition(savedPreset == Data("user preset".utf8))
        let savedProject = try Data(contentsOf: project)
        precondition(savedProject == Data("project".utf8))
        precondition(defaults.string(forKey: "orca.ios.printer-connections.v1") == "connection metadata")

        // A directory's mere existence cannot mark an interrupted install as complete.
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        try first.prepareProfiles()
        precondition(!fm.fileExists(atPath: system.path))
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: system.appendingPathComponent("vendor.json"))
        try first.profilesLoaded()
        try first.prepareProfiles()
        precondition(fm.fileExists(atPath: system.appendingPathComponent("vendor.json").path))
        let next = StartupRecovery(defaults: defaults, dataDirectory: directory, revision: "v2")
        try next.prepareProfiles()
        precondition(!fm.fileExists(atPath: system.path))
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        try next.profilesLoaded()
        try next.prepareProfiles(rebuild: true)
        precondition(!fm.fileExists(atPath: system.path))
        print("PASS: interrupted startup, profile revision changes, partial installs, explicit rebuild and preserved user files")
    }
}
