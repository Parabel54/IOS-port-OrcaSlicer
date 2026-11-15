import Foundation
import Combine

@MainActor
final class OrcaCloudAccount: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var displayName = ""
    @Published private(set) var printers: [OrcaCloudPrinter] = []
    @Published private(set) var busy = false
    @Published private(set) var signingIn = false
    @Published private(set) var lastSynced: Date?
    @Published var message = ""
    private var cloudSession: OrcaCloudSession?
    private let api: OrcaCloudAPI
    private let credentials: PrinterCredentialStore
    private let authentication = NativeCloudSignIn()
    private var generation = UUID()
    // A distinct stable Keychain item; never serialize tokens into preferences.
    private static let credentialID = UUID(uuidString: "C8CD1A34-87A2-49B5-905C-94015DFEA763")!

    init(api: OrcaCloudAPI = OrcaCloudAPI(), credentials: PrinterCredentialStore = .keychain) {
        self.api = api
        self.credentials = credentials
        do {
            let stored = try credentials.read(Self.credentialID)
            if !stored.isEmpty {
                let session = try JSONDecoder().decode(OrcaCloudSession.self, from: Data(stored.utf8))
                guard !session.access_token.isEmpty, !session.refresh_token.isEmpty, !session.user.id.isEmpty else {
                    throw OrcaCloudError.invalidResponse
                }
                cloudSession = session
                signedIn = true
                displayName = session.displayName
            }
        } catch { message = String(localized: "Could not restore the cloud session. Sign in again.") }
    }

    func signIn(provider: String) async {
        guard !busy else { return }
        busy = true
        signingIn = true
        let current = generation
        defer { if generation == current { busy = false; signingIn = false } }
        do {
            let authorization = try await authentication.signIn(provider: provider)
            let session = try await api.exchange(code: authorization.code, verifier: authorization.verifier)
            guard generation == current else { return }
            try install(session)
            signingIn = false
            let result = try await api.printers(accessToken: session.access_token)
            guard generation == current else { return }
            printers = result
            lastSynced = Date()
            message = String(localized: "Account and printers synchronized.")
        } catch {
            guard generation == current else { return }
            message = error.localizedDescription
        }
    }

    func cancelSignIn() {
        guard signingIn else { return }
        generation = UUID()
        authentication.cancel()
        signingIn = false
        busy = false
        message = OrcaCloudError.cancelled.localizedDescription
    }

    func sync() async {
        guard !busy, var session = cloudSession else { return }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do {
            if session.expiry.timeIntervalSinceNow < 60 {
                session = try await refreshSession(session, generation: current)
            }
            let result: [OrcaCloudPrinter]
            do { result = try await api.printers(accessToken: session.access_token) }
            catch OrcaCloudError.http(401) {
                session = try await refreshSession(session, generation: current)
                result = try await api.printers(accessToken: session.access_token)
            }
            guard generation == current else { return }
            printers = result
            lastSynced = Date()
            message = String(localized: "Account and printers synchronized.")
        } catch {
            guard generation == current else { return }
            // Preserve the local session on transient failures; never erase LAN keys.
            message = error.localizedDescription
        }
    }

    func signOut() async {
        let token = cloudSession?.access_token
        do { try credentials.remove(Self.credentialID) }
        catch { message = OrcaCloudError.storage.localizedDescription; return }
        generation = UUID()
        busy = false
        signingIn = false
        authentication.cancel()
        cloudSession = nil
        signedIn = false
        displayName = ""
        printers = []
        lastSynced = nil
        message = ""
        if let token { try? await api.logout(accessToken: token) }
    }

    private func refreshSession(_ session: OrcaCloudSession, generation current: UUID) async throws -> OrcaCloudSession {
        let refreshed: OrcaCloudSession
        do { refreshed = try await api.refresh(session.refresh_token) }
        catch OrcaCloudError.http(let status) where status == 400 || status == 401 {
            guard generation == current else { throw CancellationError() }
            do { try credentials.remove(Self.credentialID) }
            catch { throw OrcaCloudError.storage }
            generation = UUID()
            busy = false
            cloudSession = nil
            signedIn = false
            displayName = ""
            printers = []
            lastSynced = nil
            message = String(localized: "Your cloud session has expired. Sign in again.")
            throw OrcaCloudError.http(status)
        }
        guard generation == current else { throw CancellationError() }
        guard refreshed.user.id == session.user.id else { throw OrcaCloudError.invalidResponse }
        try install(refreshed)
        return refreshed
    }

    private func install(_ session: OrcaCloudSession) throws {
        do { try credentials.write(Self.credentialID, String(decoding: JSONEncoder().encode(session), as: UTF8.self)) }
        catch { throw OrcaCloudError.storage }
        cloudSession = session
        signedIn = true
        displayName = session.displayName
    }
}
