import Foundation
import Combine
import Security

struct PrinterConnection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let address: String
    let kind: String
    var cloudPrinterID: String? = nil

    static func validatedURL(_ address: String) -> URL? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }
}

// Only connection metadata lives in preferences. API keys stay in the device Keychain.
struct PrinterCredentialStore {
    var read: (UUID) throws -> String
    var write: (UUID, String) throws -> Void
    var remove: (UUID) throws -> Void

    static let keychain = PrinterCredentialStore(
        read: { id in
            var query = keychainQuery(id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return "" }
            try check(status)
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw ConnectionError.credential
            }
            return key
        },
        write: { id, key in
            if key.isEmpty {
                try delete(id)
                return
            }
            let query = keychainQuery(id)
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query.merging(attributes) { _, value in value }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                try check(SecItemAdd(item as CFDictionary, nil))
            } else {
                try check(status)
            }
        },
        remove: { try delete($0) }
    )

    private static func keychainQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.orcaslicer.ios.printer-credentials",
         kSecAttrAccount as String: id.uuidString]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ConnectionError.credential }
    }

    private static func delete(_ id: UUID) throws {
        let status = SecItemDelete(keychainQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

enum ConnectionError: LocalizedError {
    case invalidAddress, invalidName, credential
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return String(localized: "Enter an HTTP or HTTPS printer URL without a username, password, query, or fragment.")
        case .invalidName: return String(localized: "Enter a name for this printer.")
        case .credential: return String(localized: "Could not access printer credentials in Keychain. Unlock your device and try again.")
        }
    }
}

@MainActor
final class PrinterConnections: ObservableObject {
    @Published private(set) var printers: [PrinterConnection] = []
    @Published var message = ""
    private let defaults: UserDefaults
    private let credentials: PrinterCredentialStore
    private let storageKey = "orca.ios.printer-connections.v1"
    private var canSave = true

    init(defaults: UserDefaults = .standard, credentials: PrinterCredentialStore = .keychain) {
        self.defaults = defaults
        self.credentials = credentials
        if let data = defaults.data(forKey: storageKey) {
            do { printers = try JSONDecoder().decode([PrinterConnection].self, from: data) }
            catch {
                canSave = false
                message = String(localized: "Saved printer connections could not be read. They have not been overwritten.")
            }
        }
    }

    func save(name: String, address: String, kind: String, apiKey: String) {
        guard canSave else { return }
        do {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ConnectionError.invalidName }
            guard let url = PrinterConnection.validatedURL(address) else { throw ConnectionError.invalidAddress }
            let address = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let existing = printers.firstIndex { $0.address == address && $0.kind == kind }
            let printer = PrinterConnection(id: existing.map { printers[$0].id } ?? UUID(),
                                            name: name, address: address, kind: kind,
                                            cloudPrinterID: existing.flatMap { printers[$0].cloudPrinterID })
            var updated = printers
            if let existing { updated[existing] = printer } else { updated.append(printer) }
            let data = try JSONEncoder().encode(updated)
            try credentials.write(printer.id, apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            defaults.set(data, forKey: storageKey)
            printers = updated
            message = String(localized: "Printer connection saved.")
        } catch { message = error.localizedDescription }
    }

    func link(_ printer: PrinterConnection, toCloudPrinter cloudID: String?) {
        guard canSave, let index = printers.firstIndex(where: { $0.id == printer.id }) else { return }
        var updated = printers
        // A cloud printer has at most one corresponding local connection.
        if let cloudID {
            for i in updated.indices where updated[i].cloudPrinterID == cloudID {
                updated[i].cloudPrinterID = nil
            }
        }
        updated[index].cloudPrinterID = cloudID
        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: storageKey)
            printers = updated
            message = ""
        } catch { message = error.localizedDescription }
    }

    func apiKey(for printer: PrinterConnection) throws -> String {
        try credentials.read(printer.id)
    }

    func remove(_ printer: PrinterConnection) {
        guard canSave else { return }
        do {
            let updated = printers.filter { $0.id != printer.id }
            let data = try JSONEncoder().encode(updated)
            try credentials.remove(printer.id)
            defaults.set(data, forKey: storageKey)
            printers = updated
            message = ""
        } catch { message = error.localizedDescription }
    }
}
