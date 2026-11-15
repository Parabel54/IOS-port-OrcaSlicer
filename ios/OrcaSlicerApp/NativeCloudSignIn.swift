import Foundation
import AuthenticationServices
import Network
import UIKit

@MainActor
final class NativeCloudSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var server: OrcaOAuthLoopbackServer?
    private var continuation: CheckedContinuation<(code: String, verifier: String), Error>?
    private var timeout: Task<Void, Never>?

    func signIn(provider: String) async throws -> (code: String, verifier: String) {
        guard continuation == nil else { throw OrcaCloudError.unavailable }
        let pkce = try OrcaPKCE()
        let url = try pkce.authorizationURL(provider: provider)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let server = try OrcaOAuthLoopbackServer(pkce: pkce)
                    self.server = server
                    server.start(onReady: { [weak self] in
                        Task { @MainActor in self?.openBrowser(url: url) }
                    }, onCode: { [weak self] code in
                        Task { @MainActor in self?.finish(.success((code, pkce.verifier))) }
                    }, onFailure: { [weak self] in
                        Task { @MainActor in self?.finish(.failure(OrcaCloudError.unavailable)) }
                    })
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 300_000_000_000) }
                        catch { return }
                        self?.finish(.failure(OrcaCloudError.timedOut))
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() { finish(.failure(OrcaCloudError.cancelled)) }

    private func openBrowser(url: URL) {
        guard continuation != nil else { return }
        // Match the desktop loopback redirect already registered with the service;
        // no unregistered iOS URL scheme is substituted for that redirect.
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in self?.finish(.failure(OrcaCloudError.cancelled)) }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        self.browser = browser
        if !browser.start() { finish(.failure(OrcaCloudError.unavailable)) }
    }

    private func finish(_ result: Result<(code: String, verifier: String), Error>) {
        guard let continuation else { return }
        self.continuation = nil // Browser cancellation must not complete a consumed flow.
        timeout?.cancel()
        timeout = nil
        server?.cancel()
        server = nil
        browser?.cancel()
        browser = nil
        continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

/// The registered desktop callback uses localhost. Only loopback peers are
/// accepted, with a bounded HTTP request, exact host/path and one-time PKCE state.
private final class OrcaOAuthLoopbackServer {
    private let pkce: OrcaPKCE
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.orcaslicer.ios.oauth-loopback")
    private var consumed = false

    init(pkce: OrcaPKCE) throws {
        self.pkce = pkce
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: pkce.port)!)
    }

    func start(onReady: @escaping () -> Void, onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady()
            case .failed: onFailure()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, Self.isLoopback(connection.endpoint) else { connection.cancel(); return }
            connection.start(queue: self.queue)
            let expiry = DispatchWorkItem { connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + 10, execute: expiry)
            self.read(connection, buffer: Data(), expiry: expiry, onCode: onCode)
        }
        listener.start(queue: queue)
    }

    func cancel() { listener.cancel() }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue == Data([127, 0, 0, 1])
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes == [UInt8](repeating: 0, count: 15) + [1] ||
                bytes == [UInt8](repeating: 0, count: 10) + [255, 255, 127, 0, 0, 1]
        default: return false
        }
    }

    private func read(_ connection: NWConnection, buffer: Data, expiry: DispatchWorkItem, onCode: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { expiry.cancel(); connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192, error == nil else { expiry.cancel(); connection.cancel(); return }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").components(separatedBy: " ")
                let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() }
                let allowedHosts = ["localhost:\(self.pkce.port)", "127.0.0.1:\(self.pkce.port)", "[::1]:\(self.pkce.port)"]
                let code: String?
                if !self.consumed, request.count == 3, request[0] == "GET", request[2].hasPrefix("HTTP/1."),
                   hosts.count == 1, allowedHosts.contains(hosts[0]) {
                    code = try? self.pkce.code(from: request[1])
                } else { code = nil }
                if code != nil { self.consumed = true }
                let body = code == nil ? "Invalid sign-in callback." : "Sign-in received. You can return to OrcaSlicer."
                let response = "HTTP/1.1 \(code == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    expiry.cancel()
                    connection.cancel()
                    if let code { onCode(code) }
                })
            } else if complete {
                expiry.cancel()
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer, expiry: expiry, onCode: onCode)
            }
        }
    }
}
