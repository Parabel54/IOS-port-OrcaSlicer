import Foundation
import Combine

@MainActor
protocol OrcaCloudAuthenticating: AnyObject {
    func signIn(provider: String) async throws -> (code: String, verifier: String)
    func signInSSO(domain: String) async throws -> (code: String, verifier: String)
    func cancel()
}

extension OrcaCloudAuthenticating {
    func signInSSO(domain: String) async throws -> (code: String, verifier: String) { throw OrcaCloudError.unavailable }
}

@MainActor
final class OrcaCloudAccount: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var displayName = ""
    @Published private(set) var printers: [OrcaCloudPrinter] = []
    @Published private(set) var busy = false
    @Published private(set) var signingIn = false
    @Published private(set) var lastSynced: Date?
    @Published var message = ""
    @Published private(set) var providers = [OrcaLoginProvider(id: "google")]
    @Published private(set) var emailEnabled = false
    @Published private(set) var phoneEnabled = false
    @Published private(set) var ssoEnabled = false
    @Published private(set) var pendingPhone: String?
    @Published private(set) var needsMFACode = false
    @Published private(set) var mfaDescription = ""
    private var pendingMFA: (session: OrcaCloudSession, factor: OrcaMFAFactor, challenge: String)?
    private var loadingMethods = false
    private var cloudSession: OrcaCloudSession?
    private let api: OrcaCloudAPI
    private let credentials: PrinterCredentialStore
    private let authentication: OrcaCloudAuthenticating
    private var generation = UUID()
    // A distinct stable Keychain item; never serialize tokens into preferences.
    private static let credentialID = UUID(uuidString: "C8CD1A34-87A2-49B5-905C-94015DFEA763")!

    init(api: OrcaCloudAPI = OrcaCloudAPI(), credentials: PrinterCredentialStore = .keychain, authentication: OrcaCloudAuthenticating) {
        self.authentication = authentication
        self.api = api
        self.credentials = credentials
        do {
            let stored = try credentials.read(Self.credentialID)
            if !stored.isEmpty {
                let session = try JSONDecoder().decode(OrcaCloudSession.self, from: Data(stored.utf8))
                guard !session.access_token.isEmpty, !session.refresh_token.isEmpty, !session.user.id.isEmpty, !session.needsMFA else {
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
            try await completeSignIn(session, generation: current)
        } catch {
            guard generation == current else { return }
            message = error.localizedDescription
        }
    }

    func loadLoginMethods() async {
        guard !loadingMethods else { return }
        loadingMethods = true
        defer { loadingMethods = false }
        do {
            let methods = try await api.authMethods()
            providers = methods.providers
            emailEnabled = methods.external["email"] == true
            phoneEnabled = methods.external["phone"] == true
            ssoEnabled = methods.saml_enabled == true
        } catch { if message.isEmpty && !busy { message = error.localizedDescription } }
    }

    func signIn(email: String, password: String) async {
        guard !busy else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            message = String(localized: "Enter your email address and password.")
            return
        }
        busy = true
        signingIn = true
        let current = generation
        defer { if generation == current { busy = false; signingIn = false } }
        do {
            let session = try await api.password(email: email, password: password)
            try await completeSignIn(session, generation: current)
        } catch { if generation == current { message = error.localizedDescription } }
    }

    func signInSSO(domain: String) async {
        guard !busy else { return }
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return }
        busy = true
        signingIn = true
        let current = generation
        defer { if generation == current { busy = false; signingIn = false } }
        do {
            let code = try await authentication.signInSSO(domain: domain)
            let session = try await api.exchange(code: code.code, verifier: code.verifier)
            try await completeSignIn(session, generation: current)
        } catch { if generation == current { message = error.localizedDescription } }
    }

    func requestSMS(phone: String) async {
        guard !busy else { return }
        let phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.hasPrefix("+"), phone.dropFirst().allSatisfy(\.isNumber), phone.count > 5 else {
            message = String(localized: "Enter an international phone number beginning with + and the country code.")
            return
        }
        busy = true
        signingIn = true
        let current = generation
        defer { if generation == current { busy = false; signingIn = false } }
        do {
            try await api.sendSMS(phone: phone)
            guard generation == current else { return }
            pendingPhone = phone
            message = String(localized: "Enter the code sent to your phone.")
        } catch { if generation == current { message = error.localizedDescription } }
    }

    func verifyCode(_ code: String) async {
        guard !busy else { return }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...10).contains(code.count), code.allSatisfy(\.isNumber) else {
            message = String(localized: "Enter the verification code.")
            return
        }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do {
            if let pendingMFA {
                let verified = try await api.verifyMFA(factor: pendingMFA.factor, challenge: pendingMFA.challenge, code: code, session: pendingMFA.session)
                try await completeSignIn(verified, generation: current, checkMFA: false)
            } else if let phone = pendingPhone {
                let verified = try await api.verifySMS(phone: phone, code: code)
                try await completeSignIn(verified, generation: current)
            }
        } catch { if generation == current { message = error.localizedDescription } }
    }

    private func completeSignIn(_ session: OrcaCloudSession, generation current: UUID, checkMFA: Bool = true) async throws {
        guard generation == current else { return }
        if checkMFA && session.needsMFA {
            guard let factor = session.user.factors?.first(where: { $0.status == "verified" && ["totp", "phone"].contains($0.factor_type) }) else {
                throw OrcaCloudError.verificationUnavailable
            }
            let challenge = try await api.challenge(factor: factor, session: session)
            guard generation == current else { return }
            pendingMFA = (session, factor, challenge)
            needsMFACode = true
            mfaDescription = factor.factor_type == "totp" ? String(localized: "Enter your authenticator code.") : String(localized: "Enter the code sent to your registered phone.")
            return
        }
        try install(session)
        pendingMFA = nil
        pendingPhone = nil
        needsMFACode = false
        signingIn = false
        let result = try await api.printers(accessToken: session.access_token)
        guard generation == current else { return }
        printers = result
        lastSynced = Date()
        message = String(localized: "Account and printers synchronized.")
    }

    func cancelSignIn() {
        guard signingIn || pendingPhone != nil || pendingMFA != nil else { return }
        generation = UUID()
        authentication.cancel()
        signingIn = false
        busy = false
        pendingPhone = nil
        pendingMFA = nil
        needsMFACode = false
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
        pendingMFA = nil
        pendingPhone = nil
        needsMFACode = false
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
