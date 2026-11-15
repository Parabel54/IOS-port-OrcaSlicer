import Foundation

@main
struct PrinterConnectionsSmoke {
    @MainActor
    static func main() throws {
        let domain = "OrcaPrinterConnectionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var keys: [UUID: String] = [:]
        var failWrites = false
        let credentials = PrinterCredentialStore(
            read: { keys[$0] ?? "" },
            write: { id, key in
                if failWrites { throw ConnectionError.credential }
                keys[id] = key
            },
            remove: { keys.removeValue(forKey: $0) }
        )
        let store = PrinterConnections(defaults: defaults, credentials: credentials)
        store.save(name: "Workshop", address: "http://klipper.local/", kind: "Moonraker", apiKey: "secret-one")
        store.save(name: "Office", address: "https://octopi.local/octoprint", kind: "OctoPrint", apiKey: "secret-two")
        precondition(store.printers.count == 2)
        let first = store.printers[0]
        let firstKey = try store.apiKey(for: first)
        precondition(firstKey == "secret-one")
        store.save(name: "Renamed", address: "http://klipper.local", kind: "Moonraker", apiKey: "updated-secret")
        precondition(store.printers.count == 2 && store.printers[0].id == first.id)
        let restored = PrinterConnections(defaults: defaults, credentials: credentials)
        precondition(restored.printers == store.printers)
        let restoredKey = try restored.apiKey(for: first)
        precondition(restoredKey == "updated-secret")
        let data = defaults.data(forKey: "orca.ios.printer-connections.v1")!
        precondition(!String(decoding: data, as: UTF8.self).contains("secret"))
        failWrites = true
        store.save(name: "Failed", address: "http://another.local", kind: "Moonraker", apiKey: "key")
        precondition(store.printers.count == 2 && defaults.data(forKey: "orca.ios.printer-connections.v1") == data)
        failWrites = false
        store.remove(first)
        precondition(store.printers.count == 1 && keys[first.id] == nil)
        let secondKey = try store.apiKey(for: store.printers[0])
        precondition(secondKey == "secret-two")
        for invalid in ["file:///tmp/job", "javascript:alert(1)", "http://", "printer.local", "https://user:password@printer.local", "http://printer.local?key=secret", "http://printer.local/#fragment", "http://printer.local:70000"] {
            precondition(PrinterConnection.validatedURL(invalid) == nil, invalid)
        }
        for valid in ["http://printer.local", "https://printer.local/path", "http://[::1]:7125"] {
            precondition(PrinterConnection.validatedURL(valid) != nil, valid)
        }
        let corrupt = Data("invalid json".utf8)
        defaults.set(corrupt, forKey: "orca.ios.printer-connections.v1")
        let damaged = PrinterConnections(defaults: defaults, credentials: credentials)
        damaged.save(name: "Replacement", address: "http://printer.local", kind: "Moonraker", apiKey: "")
        precondition(defaults.data(forKey: "orca.ios.printer-connections.v1") == corrupt)
        print("PASS: multiple printers, credential isolation, reload, update, removal, failed writes, URL validation and corrupt storage")
    }
}
