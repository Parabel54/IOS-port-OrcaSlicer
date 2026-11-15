import Foundation
import CryptoKit
import Security

// Endpoints, public application key and PKCE protocol match OrcaCloudServiceAgent.
// This is an application identifier published upstream, not a client secret.
enum OrcaCloudEndpoints {
    static let auth = URL(string: "https://auth.orcaslicer.com")!
    static let api = URL(string: "https://api.orcaslicer.com")!
    static let publicKey = "sb_publishable_lvVe_whOi80SU9BPSxM1kA_tbt9AbR_"
}

enum OrcaCloudError: LocalizedError, Equatable {
    case invalidResponse, http(Int), invalidCallback, cancelled, timedOut, storage, unavailable, verificationUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return String(localized: "Orca Cloud returned an invalid response.")
        case .http(let status): return String(localized: "Orca Cloud returned HTTP \(status). Try again or sign in again.")
        case .invalidCallback: return String(localized: "The sign-in callback could not be verified. Start a new sign-in.")
        case .cancelled: return String(localized: "Sign-in was canceled.")
        case .timedOut: return String(localized: "Sign-in timed out. Try again.")
        case .storage: return String(localized: "The cloud session could not be saved in Keychain.")
        case .verificationUnavailable: return String(localized: "This account requires a verification method that is not available in the native app. Use a configured authenticator or SMS factor.")
        case .unavailable: return String(localized: "The sign-in browser or local callback port is unavailable. Close any other sign-in and try again.")
        }
    }
}

struct OrcaPKCE {
    let verifier: String
    let state: String
    let port: UInt16
    init(port: UInt16 = 41172) throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw OrcaCloudError.unavailable
            }
            return Data(bytes).base64URL
        }
        verifier = try random()
        state = try random()
        self.port = port
    }
    // Explicit initializer supports published PKCE test vectors without weakening randomness.
    init(verifier: String, state: String, port: UInt16 = 41172) {
        self.verifier = verifier; self.state = state; self.port = port
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    func authorizationURL(provider: String) throws -> URL {
        guard !provider.isEmpty, provider.count <= 128, provider.unicodeScalars.allSatisfy({ (97...122).contains($0.value) || (48...57).contains($0.value) || "_-:.".unicodeScalars.contains($0) }) else { throw OrcaCloudError.unavailable }
        var redirect = URLComponents(string: "http://localhost:\(port)/callback")!
        redirect.queryItems = [URLQueryItem(name: "orca_state", value: state)]
        var authorization = URLComponents(url: OrcaCloudEndpoints.auth.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        authorization.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirect.url!.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "apikey", value: OrcaCloudEndpoints.publicKey)
        ]
        return authorization.url!
    }
    func code(from target: String) throws -> String {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let url = URLComponents(string: "http://localhost:\(port)" + target),
              url.path == "/callback", url.fragment == nil else { throw OrcaCloudError.invalidCallback }
        let items = url.queryItems ?? []
        let primaryStates = items.filter { $0.name == "orca_state" }
        let fallbackStates = items.filter { $0.name == "state" }
        guard primaryStates.count <= 1, fallbackStates.count <= 1 else { throw OrcaCloudError.invalidCallback }
        // Upstream prefers the app's orca_state over a provider's own state.
        let states = primaryStates.isEmpty ? fallbackStates : primaryStates
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states[0].value == state,
              codes.count == 1, let code = codes[0].value, !code.isEmpty,
              !items.contains(where: { $0.name == "error" }) else { throw OrcaCloudError.invalidCallback }
        return code
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct OrcaCloudSession: Codable {
    struct User: Codable {
        let id: String
        let email: String?
        let user_metadata: [String: String]?
        let factors: [OrcaMFAFactor]?
        // Metadata may include booleans/nested identities. Read only display fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            factors = try container.decodeIfPresent([OrcaMFAFactor].self, forKey: .factors)
            if let metadata = try? container.nestedContainer(keyedBy: DisplayKey.self, forKey: .user_metadata) {
                var values: [String: String] = [:]
                for key in metadata.allKeys {
                    if let text = try? metadata.decode(String.self, forKey: key) { values[key.stringValue] = text }
                }
                user_metadata = values
            } else { user_metadata = nil }
        }
        private struct DisplayKey: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }
    }
    let access_token: String
    let refresh_token: String
    let expires_at: Double?
    let expires_in: Double?
    let user: User
    var displayName: String {
        user.user_metadata?["display_name"] ?? user.user_metadata?["full_name"] ?? user.user_metadata?["name"] ?? user.email ?? String(localized: "Orca Cloud account")
    }
    var needsMFA: Bool {
        guard user.factors?.contains(where: { $0.status == "verified" }) == true else { return false }
        let components = access_token.split(separator: ".")
        guard components.count == 3 else { return true }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return claims["aal"] as? String != "aal2"
    }
    var expiry: Date {
        Date(timeIntervalSince1970: expires_at ?? 0)
    }
}

struct OrcaCloudPrinter: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let model: String?
    let access_role: String?
    let status_snapshot: Snapshot?
    struct Snapshot: Decodable, Equatable {
        let status: Status?
        struct Status: Decodable, Equatable {
            let connection: Connection?
            let job: Job?
            struct Connection: Decodable, Equatable { let state: String? }
            struct Job: Decodable, Equatable { let state: String? }
        }
    }
    var online: Bool { status_snapshot?.status?.connection?.state == "online" }
    var jobState: String? { status_snapshot?.status?.job?.state }
}

struct OrcaLoginProvider: Identifiable, Equatable {
    let id: String
    var name: String {
        switch id {
        case "google": return "Google"
        case "github": return "GitHub"
        case "apple": return "Apple"
        case "azure": return "Microsoft"
        case "linkedin", "linkedin_oidc": return "LinkedIn"
        case "gitlab": return "GitLab"
        case "keycloak": return "Keycloak"
        case "workos": return "WorkOS"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct OrcaAuthMethods: Decodable {
    let external: [String: Bool]
    let saml_enabled: Bool?
    var providers: [OrcaLoginProvider] {
        external.filter { $0.value && $0.key != "email" && $0.key != "phone" }
            .map { OrcaLoginProvider(id: $0.key) }.sorted { $0.name < $1.name }
    }
}

struct OrcaMFAFactor: Codable {
    let id: String
    let factor_type: String
    let status: String
    let friendly_name: String?
}

struct OrcaCloudAPI {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func authMethods() async throws -> OrcaAuthMethods {
        let request = URLRequest(url: OrcaCloudEndpoints.auth.appendingPathComponent("auth/v1/settings"))
        return try JSONDecoder().decode(OrcaAuthMethods.self, from: await perform(request))
    }
    func password(email: String, password: String) async throws -> OrcaCloudSession {
        try await token(grant: "password", body: ["email": email, "password": password])
    }
    func sendSMS(phone: String) async throws {
        _ = try await authenticatedPost("auth/v1/otp", body: ["phone": phone, "create_user": false, "channel": "sms"])
    }
    func verifySMS(phone: String, code: String) async throws -> OrcaCloudSession {
        try decodeSession(await authenticatedPost("auth/v1/verify", body: ["phone": phone, "token": code, "type": "sms"]))
    }
    func singleSignOn(domain: String, pkce: OrcaPKCE) async throws -> URL {
        let redirect = "http://localhost:\(pkce.port)/callback?orca_state=\(pkce.state)"
        let data = try await authenticatedPost("auth/v1/sso", body: ["domain": domain, "redirect_to": redirect,
            "code_challenge": pkce.challenge, "code_challenge_method": "s256", "skip_http_redirect": true])
        struct Response: Decodable { let url: String }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let url = URL(string: response.url), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw OrcaCloudError.invalidResponse }
        return url
    }
    func challenge(factor: OrcaMFAFactor, session: OrcaCloudSession) async throws -> String {
        guard UUID(uuidString: factor.id) != nil else { throw OrcaCloudError.invalidResponse }
        let data = try await authenticatedPost("auth/v1/factors/\(factor.id)/challenge", body: factor.factor_type == "phone" ? ["channel": "sms"] : [:], accessToken: session.access_token)
        struct Response: Decodable { let id: String }
        let challenge = try JSONDecoder().decode(Response.self, from: data).id
        guard !challenge.isEmpty else { throw OrcaCloudError.invalidResponse }
        return challenge
    }
    func verifyMFA(factor: OrcaMFAFactor, challenge: String, code: String, session: OrcaCloudSession) async throws -> OrcaCloudSession {
        guard UUID(uuidString: factor.id) != nil else { throw OrcaCloudError.invalidResponse }
        let data = try await authenticatedPost("auth/v1/factors/\(factor.id)/verify", body: ["challenge_id": challenge, "code": code], accessToken: session.access_token)
        return try decodeSession(data, fallbackUser: session.user)
    }
    private func authenticatedPost(_ path: String, body: [String: Any], accessToken: String? = nil) async throws -> Data {
        var request = URLRequest(url: OrcaCloudEndpoints.auth.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    func exchange(code: String, verifier: String) async throws -> OrcaCloudSession {
        try await token(grant: "pkce", body: ["auth_code": code, "code_verifier": verifier])
    }
    func refresh(_ refreshToken: String) async throws -> OrcaCloudSession {
        try await token(grant: "refresh_token", body: ["refresh_token": refreshToken])
    }
    private func token(grant: String, body: [String: String]) async throws -> OrcaCloudSession {
        var parts = URLComponents(url: OrcaCloudEndpoints.auth.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "grant_type", value: grant)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue(OrcaCloudEndpoints.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await perform(request)
        return try decodeSession(data)
    }
    private func decodeSession(_ data: Data, fallbackUser: OrcaCloudSession.User? = nil) throws -> OrcaCloudSession {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_at: Double?
            let expires_in: Double?
            let user: OrcaCloudSession.User?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.access_token.isEmpty, !decoded.refresh_token.isEmpty,
              let user = decoded.user ?? fallbackUser, !user.id.isEmpty else { throw OrcaCloudError.invalidResponse }
        let absolute = decoded.expires_at ?? Date().timeIntervalSince1970 + (decoded.expires_in ?? 0)
        guard absolute.isFinite else { throw OrcaCloudError.invalidResponse }
        return OrcaCloudSession(access_token: decoded.access_token, refresh_token: decoded.refresh_token,
                                expires_at: absolute, expires_in: decoded.expires_in, user: user)
    }

    func printers(accessToken: String) async throws -> [OrcaCloudPrinter] {
        var request = URLRequest(url: OrcaCloudEndpoints.api.appendingPathComponent("api/v1/printers"))
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        struct Envelope: Decodable { let data: [OrcaCloudPrinter] }
        let response = try await perform(request)
        let printers = try JSONDecoder().decode(Envelope.self, from: response).data
        guard Set(printers.map(\.id)).count == printers.count, printers.allSatisfy({ !$0.id.isEmpty }) else {
            throw OrcaCloudError.invalidResponse
        }
        return printers
    }
    func logout(accessToken: String) async throws {
        var parts = URLComponents(url: OrcaCloudEndpoints.auth.appendingPathComponent("auth/v1/logout"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "scope", value: "local")]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue(OrcaCloudEndpoints.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        _ = try await perform(request)
    }
    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        request.setValue(OrcaCloudEndpoints.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: OrcaCloudNoRedirect())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OrcaCloudError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw OrcaCloudError.http(http.statusCode) }
        return data
    }
}

private final class OrcaCloudNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
