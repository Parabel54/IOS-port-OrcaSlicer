import Foundation

private final class CloudFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw OrcaCloudError.invalidResponse }
            let (status, body) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { throw OrcaCloudError.invalidResponse }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count == 0 { return result }
        guard count > 0 else { throw OrcaCloudError.invalidResponse }
        result.append(contentsOf: buffer.prefix(count))
    }
}

@main
struct CloudAPISmoke {
    static func main() async throws {
        let pkce = OrcaPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "expected-state")
        precondition(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM") // RFC 7636
        let authorization = try pkce.authorizationURL(provider: "google")
        let authParts = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!
        precondition(authorization.host == "auth.orcaslicer.com" && authorization.path == "/auth/v1/authorize")
        let redirect = authParts.queryItems!.first(where: { $0.name == "redirect_to" })!.value!
        precondition(redirect == "http://localhost:41172/callback?orca_state=expected-state")
        let valid = try pkce.code(from: "/callback?code=one-time-code&orca_state=expected-state")
        precondition(valid == "one-time-code")
        for invalid in ["/callback?code=x&orca_state=wrong", "/callback?code=x", "/other?code=x&state=expected-state", "/callback?code=x&code=y&state=expected-state", "/callback?code=x&orca_state=expected-state&orca_state=expected-state", "//evil/callback?code=x&state=expected-state", "/callback?error=denied&code=x&state=expected-state"] {
            do { _ = try pkce.code(from: invalid); preconditionFailure("Unverified callback accepted") }
            catch OrcaCloudError.invalidCallback {}
        }
        let preferred = try pkce.code(from: "/callback?code=x&state=provider-state&orca_state=expected-state")
        precondition(preferred == "x")
        let first = try OrcaPKCE(), second = try OrcaPKCE()
        precondition(first.state != second.state && first.verifier != second.verifier && first.verifier.count >= 43)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = OrcaCloudAPI(session: session)
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/auth/v1/token" && request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "apikey") == OrcaCloudEndpoints.publicKey)
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            precondition(body["auth_code"] == "one-time-code" && body["code_verifier"] == pkce.verifier)
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "pkce")
            return (200, Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"user":{"id":"account-1","email":"person@example.invalid","user_metadata":{"full_name":"Test Account","email_verified":true,"nested":{"ignored":true}}}}"#.utf8))
        }
        let account = try await api.exchange(code: valid, verifier: pkce.verifier)
        precondition(account.user.id == "account-1" && account.displayName == "Test Account")
        precondition(account.expiry.timeIntervalSinceNow > 3500)
        let restored = try JSONDecoder().decode(OrcaCloudSession.self, from: JSONEncoder().encode(account))
        precondition(restored.expires_at == account.expires_at)
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/api/v1/printers" && request.httpMethod == "GET")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            return (200, Data(#"{"data":[{"id":"printer-1","name":"AD5X","model":"Flashforge AD5X","access_role":"owner","status_snapshot":{"status":{"connection":{"state":"online"},"job":{"state":"printing"}}}},{"id":"printer-2","name":"5M","access_role":"viewer"}]}"#.utf8))
        }
        let printers = try await api.printers(accessToken: account.access_token)
        precondition(printers.count == 2 && printers[0].online && printers[0].jobState == "printing")
        precondition(!printers[1].online && printers[1].access_role == "viewer")
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/api/v1/sync/pull" && request.httpMethod == "GET")
            precondition(request.url!.query == nil && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            return (200, Data(#"{"upserts":[{"id":"00000000-0000-4000-8000-000000000011","name":"PLA","updated_time":42,"content":{"name":"PLA","type":"filament","version":"2.5.1","filament_settings_id":["PLA"]}}],"deletes":[],"next_cursor":42}"#.utf8))
        }
        let profiles = try await api.profiles(accessToken: "fixture-access")
        precondition(profiles.count == 1 && profiles[0].kind == "filament" && profiles[0].updatedTime == 42)
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/api/v1/sync/push" && request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(body["original_updated_time"] as? String == "42")
            precondition((body["content"] as? [String: Any])?["filament_settings_id"] as? [String] == ["PLA"])
            return (200, Data(#"{"updated_time":43}"#.utf8))
        }
        let acknowledged = try await api.pushProfile(profiles[0], id: profiles[0].id, originalTime: 42, accessToken: "fixture-access")
        precondition(acknowledged == 43)
        CloudFixtureProtocol.handler = { _ in (409, Data()) }
        do { _ = try await api.pushProfile(profiles[0], id: profiles[0].id, originalTime: 42, accessToken: "fixture-access"); preconditionFailure("Conflict ignored") }
        catch OrcaCloudError.http(409) {}
        print("PASS: full cloud preset snapshot, typed filament content, conflict-checked push and no force overwrite")
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            precondition(body == ["refresh_token":"fixture-refresh"])
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "refresh_token")
            return (200, Data(#"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_at":4102444800,"user":{"id":"account-1"}}"#.utf8))
        }
        let rotated = try await api.refresh(account.refresh_token)
        precondition(rotated.refresh_token == "rotated-refresh")
        for status in [401, 403, 500] {
            CloudFixtureProtocol.handler = { _ in (status, Data("Do not expose server secrets".utf8)) }
            do { _ = try await api.printers(accessToken: "fixture-access"); preconditionFailure("HTTP failure accepted") }
            catch OrcaCloudError.http(let actual) { precondition(actual == status) }
        }
        CloudFixtureProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"duplicate","name":"A"},{"id":"duplicate","name":"B"}]}"#.utf8)) }
        do { _ = try await api.printers(accessToken: "fixture-access"); preconditionFailure("Duplicate printer IDs accepted") }
        catch OrcaCloudError.invalidResponse {}
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/auth/v1/logout" && request.httpMethod == "POST")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first?.value == "local")
            return (204, Data())
        }
        try await api.logout(accessToken: "fixture-access")
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/auth/v1/settings")
            return (200, Data(#"{"external":{"apple":true,"facebook":true,"github":true,"google":true,"email":true,"phone":false,"discord":false},"saml_enabled":false}"#.utf8))
        }
        let methods = try await api.authMethods()
        precondition(Set(methods.providers.map(\.id)) == ["apple", "facebook", "github", "google"])
        precondition(methods.external["email"] == true && methods.external["phone"] == false)
        for provider in methods.providers {
            let url = try pkce.authorizationURL(provider: provider.id)
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first?.value == provider.id)
        }
        let simpleSession = Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"user":{"id":"account-1"}}"#.utf8)
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            precondition(body["email"] == "person@example.invalid" && body["password"] == "fixture-password")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first?.value == "password")
            return (200, simpleSession)
        }
        _ = try await api.password(email: "person@example.invalid", password: "fixture-password")
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(request.url!.path == "/auth/v1/otp" && body["phone"] as? String == "+12025550123")
            precondition(body["create_user"] as? Bool == false && body["channel"] as? String == "sms")
            return (200, Data("{}".utf8))
        }
        try await api.sendSMS(phone: "+12025550123")
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            precondition(request.url!.path == "/auth/v1/verify" && body["type"] == "sms" && body["token"] == "123456")
            return (200, simpleSession)
        }
        _ = try await api.verifySMS(phone: "+12025550123", code: "123456")
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            precondition(request.url!.path == "/auth/v1/sso" && body["domain"] as? String == "example.invalid")
            precondition(body["code_challenge"] as? String == pkce.challenge && body["skip_http_redirect"] as? Bool == true)
            return (200, Data(#"{"url":"https://idp.example.invalid/authorize"}"#.utf8))
        }
        let sso = try await api.singleSignOn(domain: "example.invalid", pkce: pkce)
        precondition(sso.host == "idp.example.invalid")
        let factor = OrcaMFAFactor(id: "00000000-0000-4000-8000-000000000001", factor_type: "totp", status: "verified", friendly_name: nil)
        CloudFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/auth/v1/factors/\(factor.id)/challenge")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            return (200, Data(#"{"id":"challenge-1"}"#.utf8))
        }
        let challenge = try await api.challenge(factor: factor, session: account)
        CloudFixtureProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
            precondition(request.url!.path == "/auth/v1/factors/\(factor.id)/verify" && body["challenge_id"] == challenge && body["code"] == "123456")
            return (200, Data(#"{"access_token":"mfa-access","refresh_token":"mfa-refresh","expires_in":3600}"#.utf8))
        }
        let mfa = try await api.verifyMFA(factor: factor, challenge: challenge, code: "123456", session: account)
        precondition(mfa.user.id == account.user.id && mfa.refresh_token == "mfa-refresh")
        print("PASS: enabled-provider discovery, email/password, SMS, organization SSO and MFA protocol requests")
        print("PASS: native PKCE, callback validation, token exchange/rotation, absolute expiry, printer sync and HTTP failures")
    }
}
