import Foundation

private final class AccountFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data, Double))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { preconditionFailure("Missing account fixture") }
        let (status, data, delay) = handler(request)
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
        for _ in 0..<100 where authentication.pending == nil { try await Task.sleep(nanoseconds: 1_000_000) }
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
        for _ in 0..<100 where !fetchingPrinters { try await Task.sleep(nanoseconds: 1_000_000) }
        precondition(fetchingPrinters && loggingOut.signedIn)
        await loggingOut.signOut()
        await login.value
        precondition(!loggingOut.signedIn && loggingOut.printers.isEmpty && stored == nil && !loggingOut.busy)
        print("PASS: account restore/sync, token rotation, 401 retry, transient failure, expired-session cleanup, cancel and logout races")
    }
}
