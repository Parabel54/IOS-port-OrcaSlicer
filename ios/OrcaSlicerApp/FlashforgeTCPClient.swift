import Foundation

enum FlashforgeTCPError: LocalizedError {
    case response, closed, fileChanged, wrongPrinter, rejected(String)
    var errorDescription: String? {
        switch self {
        case .response: return String(localized: "The printer did not return a valid Flashforge TCP acknowledgement.")
        case .closed: return String(localized: "The Flashforge TCP connection closed before the command finished.")
        case .fileChanged: return String(localized: "The G-code file changed during upload. Export and upload it again.")
        case .wrongPrinter: return String(localized: "Upload this G-code to the selected printer before starting it.")
        case .rejected(let message): return String(localized: "Flashforge rejected the command: \(message)")
        }
    }
}

// One stream belongs to one operation. Injection lets host fixtures exercise the
// real acknowledgement parser and upload lifecycle without commanding a printer.
protocol FlashforgeTCPChannel: AnyObject {
    func write(_ data: Data) async throws
    func read(timeout: TimeInterval) async throws -> Data
    func close()
}

private final class FlashforgeTCPStream: FlashforgeTCPChannel {
    private let task: URLSessionStreamTask

    init(host: String, port: Int) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        task.resume()
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.write(data, timeout: 10) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }, onCancel: { self.task.cancel() })
        try Task.checkCancellation()
    }

    func read(timeout: TimeInterval) async throws -> Data {
        try Task.checkCancellation()
        let data: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                task.readData(ofMinLength: 1, maxLength: 65_536, timeout: timeout) { data, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
        }, onCancel: { self.task.cancel() })
        try Task.checkCancellation()
        return data
    }

    func close() { task.cancel() }
}

private final class FlashforgeTCPConsole {
    let channel: FlashforgeTCPChannel
    private var pending = Data()

    init(_ channel: FlashforgeTCPChannel) { self.channel = channel }

    func command(_ command: String) async throws -> [String] {
        try Task.checkCancellation()
        try await channel.write(Data((command + "\r\n").utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lines: [String] = []
        var received = pending.count
        while true {
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(...newline)
                if line.lowercased() == "ok" { return lines }
                if line.lowercased().hasPrefix("error") || line.hasPrefix("!!") {
                    throw FlashforgeTCPError.rejected(line)
                }
                if !line.isEmpty { lines.append(line) }
            }
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, received < 65_536 else { throw FlashforgeTCPError.response }
            let data = try await channel.read(timeout: remaining)
            guard !data.isEmpty else { throw FlashforgeTCPError.closed }
            received += data.count
            guard received <= 65_536 else { throw FlashforgeTCPError.response }
            pending.append(data)
        }
    }
}

struct FlashforgeTCPUploadedJob {
    let filename: String
    let source: URL
    let endpoint: URL
}

// The legacy transport in desktop Flashforge.cpp: control on one connection,
// M28 + unframed 4 KiB file chunks on a second, then M29 on a third after 3s.
// It offers upload/start, not the HTTP material-station or cancel controls.
struct FlashforgeTCPClient {
    let endpoint: URL
    private let makeChannel: () -> FlashforgeTCPChannel
    private let waitForSave: () async throws -> Void

    init(address: String, makeChannel: (() -> FlashforgeTCPChannel)? = nil,
         waitForSave: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 3_000_000_000) }) throws {
        guard let url = PrinterConnection.validatedTCPURL(address), let host = url.host,
              let port = url.port else { throw ConnectionError.invalidTCPAddress }
        endpoint = url
        self.makeChannel = makeChannel ?? { FlashforgeTCPStream(host: host, port: port) }
        self.waitForSave = waitForSave
    }

    func connect(klipper: Bool) async throws -> [String] {
        let console = FlashforgeTCPConsole(makeChannel())
        defer { console.channel.close() }
        _ = try await console.command("~M601 S1")
        let device = try await console.command("~M115")
        _ = try await console.command(klipper ? "~M640" : "~M650")
        return device + (try await console.command("~M119"))
    }

    func upload(source: URL, klipper: Bool) async throws -> FlashforgeTCPUploadedJob {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size > 0 else { throw FlashforgeError.emptyFile }
        try input.seek(toOffset: 0)
        let filename = FlashforgeClient.uploadFilename(for: source)
        _ = try await connect(klipper: klipper)
        let transfer = FlashforgeTCPConsole(makeChannel())
        do {
            defer { transfer.channel.close() }
            _ = try await transfer.command("~M28 \(size) 0:/user/\(filename)")
            var sent: UInt64 = 0
            while sent < size {
                try Task.checkCancellation()
                let data = try input.read(upToCount: Int(min(4096, size - sent))) ?? Data()
                guard !data.isEmpty else { throw FlashforgeTCPError.fileChanged }
                try await transfer.channel.write(data)
                sent += UInt64(data.count)
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw FlashforgeTCPError.fileChanged }
        }
        try await waitForSave()
        try Task.checkCancellation()
        let save = FlashforgeTCPConsole(makeChannel())
        defer { save.channel.close() }
        _ = try await save.command("~M29")
        return FlashforgeTCPUploadedJob(filename: filename, source: source, endpoint: endpoint)
    }

    func start(_ job: FlashforgeTCPUploadedJob) async throws {
        guard job.endpoint == endpoint else { throw FlashforgeTCPError.wrongPrinter }
        let console = FlashforgeTCPConsole(makeChannel())
        defer { console.channel.close() }
        _ = try await console.command("~M23 0:/user/\(job.filename)")
    }
}
