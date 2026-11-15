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
        for invalid in ["/callback?code=x&orca_state=wrong", "/callback?code=x", "/other?code=x&state=expected-state", "/callback?code=x&code=y&state=expected-state", "/callback?code=x&state=expected-state&orca_state=expected-state", "//evil/callback?code=x&state=expected-state", "/callback?error=denied&code=x&state=expected-state"] {
            do { _ = try pkce.code(from: invalid); preconditionFailure("Unverified callback accepted") }
            catch OrcaCloudError.invalidCallback {}
        }
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
        print("PASS: native PKCE, callback validation, token exchange/rotation, absolute expiry, printer sync and HTTP failures")
    }
}
