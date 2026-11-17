import Foundation

private final class AccountFixtureProtocol: URLProtocol {
    static var profileResponse = Data(#"{"upserts":[],"deletes":[],"next_cursor":0}"#.utf8)
    static var handler: ((URLRequest) -> (Int, Data, Double))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { preconditionFailure("Missing account fixture") }
        let (status, data, delay) = request.url!.path.hasSuffix("sync/pull")
            ? (200, Self.profileResponse, 0.0) : handler(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class FixtureAuthentication: OrcaCloudAuthenticating {
    var pending: CheckedContinuation<(code: String, verifier: String), Error>?
    var suspend = false
    func signIn(provider: String) async throws -> (code: String, verifier: String) {
        if suspend {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return ("fixture-code", "fixture-verifier")
    }
    func cancel() {
        pending?.resume(throwing: OrcaCloudError.cancelled)
        pending = nil
    }
}

@main
struct CloudAccountSmoke {
    @MainActor
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = OrcaCloudAPI(session: session)
        var stored: String?
        let credentials = PrinterCredentialStore(read: { _ in stored ?? "" }, write: { _, value in stored = value }, remove: { _ in stored = nil })
        let token = Data(#"{"access_token":"access-one","refresh_token":"refresh-one","expires_at":4102444800,"user":{"id":"user-one","email":"test@example.invalid"}}"#.utf8)
        let expiredToken = String(decoding: token, as: UTF8.self).replacingOccurrences(of: "4102444800", with: "1")
        let rotated = Data(#"{"access_token":"access-two","refresh_token":"refresh-two","expires_at":4102444800,"user":{"id":"user-one"}}"#.utf8)
        let printerList = Data(#"{"data":[{"id":"printer-one","name":"AD5X","access_role":"owner"}]}"#.utf8)
        AccountFixtureProtocol.handler = { request in
            (200, request.url!.path.hasSuffix("token") ? token : printerList, 0)
        }
        let account = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await account.signIn(provider: "google")
        precondition(account.signedIn && !account.busy && account.printers.count == 1 && stored != nil)
        let restored = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        precondition(restored.signedIn)
        await restored.sync()
        precondition(restored.printers.count == 1 && restored.lastSynced != nil)

        stored = expiredToken
        var refreshCount = 0
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("token") { refreshCount += 1; return (200, rotated, 0) }
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-two")
            return (200, printerList, 0)
        }
        let expired = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await expired.sync()
        precondition(expired.signedIn && refreshCount == 1 && stored!.contains("refresh-two"))

        stored = String(decoding: token, as: UTF8.self)
        var printerRequests = 0
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("token") { return (200, rotated, 0) }
            printerRequests += 1
            return printerRequests == 1 ? (401, Data(), 0) : (200, printerList, 0)
        }
        let unauthorized = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await unauthorized.sync()
        precondition(printerRequests == 2 && unauthorized.printers.count == 1)

        stored = expiredToken
        AccountFixtureProtocol.handler = { _ in (500, Data("private server detail".utf8), 0) }
        let transient = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await transient.sync()
        precondition(transient.signedIn && stored == expiredToken && !transient.busy)
        precondition(!transient.message.contains("private server detail"))
        AccountFixtureProtocol.handler = { _ in (400, Data(), 0) }
        await transient.sync()
        precondition(!transient.signedIn && !transient.busy && stored == nil)

        let authentication = FixtureAuthentication()
        authentication.suspend = true
        let canceled = OrcaCloudAccount(api: api, credentials: credentials, authentication: authentication)
        let canceledTask = Task { await canceled.signIn(provider: "google") }
        for _ in 0..<2000 where authentication.pending == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(authentication.pending != nil)
        canceled.cancelSignIn()
        await canceledTask.value
        precondition(!canceled.signedIn && !canceled.busy && stored == nil)

        var fetchingPrinters = false
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("token") { return (200, token, 0) }
            if request.url!.path.hasSuffix("logout") { return (204, Data(), 0) }
            fetchingPrinters = true
            return (200, printerList, 0.2)
        }
        let loggingOut = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        let login = Task { await loggingOut.signIn(provider: "google") }
        for _ in 0..<2000 where !fetchingPrinters { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(fetchingPrinters && loggingOut.signedIn)
        await loggingOut.signOut()
        await login.value
        precondition(!loggingOut.signedIn && loggingOut.printers.isEmpty && stored == nil && !loggingOut.busy)
        stored = nil
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("settings") {
                return (200, Data(#"{"external":{"google":true,"github":true,"email":true,"phone":true},"saml_enabled":true}"#.utf8), 0)
            }
            return (200, request.url!.path.hasSuffix("token") ? token : printerList, 0)
        }
        let email = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await email.loadLoginMethods()
        precondition(email.emailEnabled && email.phoneEnabled && email.ssoEnabled && email.providers.count == 2)
        await email.signIn(email: "test@example.invalid", password: "fixture-password")
        precondition(email.signedIn && !stored!.contains("fixture-password"))
        stored = nil
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("otp") { return (200, Data("{}".utf8), 0) }
            if request.url!.path.hasSuffix("verify") { return (200, token, 0) }
            return (200, printerList, 0)
        }
        let sms = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await sms.requestSMS(phone: "+12025550123")
        precondition(sms.pendingPhone != nil && !sms.signedIn && stored == nil)
        await sms.verifyCode("123456")
        precondition(sms.signedIn && sms.pendingPhone == nil && stored != nil)

        stored = nil
        let unverified = Data(#"{"access_token":"provisional-token","refresh_token":"provisional-refresh","expires_at":4102444800,"user":{"id":"user-one","factors":[{"id":"00000000-0000-4000-8000-000000000001","factor_type":"totp","status":"verified"}]}}"#.utf8)
        let verified = Data(#"{"access_token":"e30.eyJhYWwiOiJhYWwyIn0.signature","refresh_token":"verified-refresh","expires_at":4102444800}"#.utf8)
        AccountFixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("token") { return (200, unverified, 0) }
            if request.url!.path.hasSuffix("challenge") { return (200, Data(#"{"id":"challenge-1"}"#.utf8), 0) }
            if request.url!.path.hasSuffix("verify") { return (200, verified, 0) }
            return (200, printerList, 0)
        }
        let mfa = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        await mfa.signIn(provider: "google")
        precondition(mfa.needsMFACode && !mfa.signedIn && stored == nil)
        await mfa.verifyCode("123456")
        precondition(mfa.signedIn && !mfa.needsMFACode && stored!.contains("verified-refresh"))
        let mfaRestored = OrcaCloudAccount(api: api, credentials: credentials, authentication: FixtureAuthentication())
        precondition(mfaRestored.signedIn)
        AccountFixtureProtocol.profileResponse = Data(#"{"upserts":[{"id":"00000000-0000-4000-8000-000000000011","name":"PLA","updated_time":42,"content":{"name":"PLA","type":"filament","version":"2.5.1","filament_settings_id":["PLA"]}},{"id":"00000000-0000-4000-8000-000000000012","name":"AD5X profile","updated_time":43,"content":{"name":"AD5X profile","type":"printer","version":"2.5.1","printer_settings_id":"AD5X profile"}}],"deletes":[],"next_cursor":43}"#.utf8)
        await mfa.sync()
        precondition(mfa.profiles.count == 2 && mfa.profiles[0].kind == "filament" && mfa.profiles[1].kind == "printer")
        await mfa.signOut()
        precondition(mfa.profiles.isEmpty)
        AccountFixtureProtocol.profileResponse = Data(#"{"upserts":[],"deletes":[],"next_cursor":0}"#.utf8)
        print("PASS: account sync downloads printer and filament presets and clears them on sign-out")
        print("PASS: native login capabilities, email/SMS flows and no session persistence before MFA verification")
        print("PASS: account restore/sync, token rotation, 401 retry, transient failure, expired-session cleanup, cancel and logout races")
    }
}
