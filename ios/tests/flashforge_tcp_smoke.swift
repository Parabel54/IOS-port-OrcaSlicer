import Foundation

private final class FixtureChannel: FlashforgeTCPChannel {
    var reads: [Data]
    var writes: [Data] = []
    var closed = false
    var beforeWrite: ((Int) throws -> Void)?

    init(_ reads: [String]) { self.reads = reads.map { Data($0.utf8) } }
    func write(_ data: Data) async throws {
        precondition(!closed)
        try beforeWrite?(writes.count)
        writes.append(data)
    }
    func read(timeout: TimeInterval) async throws -> Data {
        precondition(!closed && timeout > 0 && timeout <= 10)
        return reads.isEmpty ? Data() : reads.removeFirst()
    }
    func close() { precondition(!closed); closed = true }
    var commands: [String] { writes.map { String(decoding: $0, as: UTF8.self) } }
}

private final class FixtureConnections {
    var channels: [FixtureChannel]
    var opened = 0
    init(_ channels: [FixtureChannel]) { self.channels = channels }
    func next() -> FlashforgeTCPChannel {
        precondition(opened < channels.count, "Unexpected connection: upload must not start or save after failure")
        let result = channels[opened]
        opened += 1
        return result
    }
}

@main
struct FlashforgeTCPSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("job\r\nM23 injected.gcode")
        // Includes binary/NUL/non-UTF8 bytes, CR/LF and an MD5 header; transfer must
        // preserve the post-processor's exact bytes and the final short chunk.
        var bytes = Data("; md5: fixture\r\nG1 X1 E1\n".utf8)
        bytes.append(Data((0..<8203).map { UInt8($0 % 256) }))
        try bytes.write(to: source)
        let control = FixtureChannel(["CMD M601\r\no", "k\r\n", "Machine: 5M\r\nok\n", "ok\n", "Status: ready\r\nok\r\n"])
        let transfer = FixtureChannel(["CMD M28\r\nOK\r\n"])
        let save = FixtureChannel(["ok\r\n"])
        let start = FixtureChannel(["ok\r\n"])
        let connections = FixtureConnections([control, transfer, save, start])
        var delayed = false
        let client = try FlashforgeTCPClient(address: "tcp://printer.local", makeChannel: { connections.next() }, waitForSave: {
            precondition(control.closed && transfer.closed && connections.opened == 2)
            delayed = true
        })
        let job = try await client.upload(source: source, klipper: true)
        precondition(delayed && connections.opened == 3 && save.closed)
        precondition(job.filename == "job__M23_injected.gcode" && job.source == source)
        precondition(control.commands == ["~M601 S1\r\n", "~M115\r\n", "~M640\r\n", "~M119\r\n"])
        precondition(transfer.commands[0] == "~M28 \(bytes.count) 0:/user/job__M23_injected.gcode\r\n")
        let chunks = transfer.writes.dropFirst()
        precondition(chunks.map(\.count) == [4096, 4096, bytes.count - 8192])
        precondition(chunks.reduce(into: Data()) { $0.append($1) } == bytes)
        precondition(save.commands == ["~M29\r\n"] && start.writes.isEmpty)
        try await client.start(job)
        precondition(start.commands == ["~M23 0:/user/job__M23_injected.gcode\r\n"] && start.closed)
        do {
            let other = try FlashforgeTCPClient(address: "tcp://other.local", makeChannel: { preconditionFailure("Wrong printer opened") })
            try await other.start(job)
            preconditionFailure("Job accepted on a different printer")
        } catch FlashforgeTCPError.wrongPrinter {}

        let legacy = FixtureChannel(["ok\n", "legacy\nok\n", "ok\n", "ready\nok\n"])
        let legacyClient = try FlashforgeTCPClient(address: "printer.local", makeChannel: { legacy })
        let detail = try await legacyClient.connect(klipper: false)
        precondition(detail == ["legacy", "ready"] && legacy.commands[2] == "~M650\r\n" && legacy.closed)

        for response in [[], ["o"], ["Error: rejected\n"], [String(repeating: "x", count: 65_537)]] {
            let failure = FixtureChannel(response)
            let broken = try FlashforgeTCPClient(address: "printer.local", makeChannel: { failure })
            do { _ = try await broken.connect(klipper: false); preconditionFailure("Invalid acknowledgement accepted") }
            catch { precondition(failure.closed && failure.writes.count == 1) }
        }
        let failControl = FixtureChannel(["ok\n", "ok\n", "ok\n", "ok\n"])
        let failTransfer = FixtureChannel(["ok\n"])
        failTransfer.beforeWrite = { if $0 == 2 { throw URLError(.networkConnectionLost) } }
        let failed = FixtureConnections([failControl, failTransfer])
        let interrupted = try FlashforgeTCPClient(address: "printer.local", makeChannel: { failed.next() }, waitForSave: { preconditionFailure("Incomplete upload reached save") })
        do { _ = try await interrupted.upload(source: source, klipper: false); preconditionFailure("Failed transfer accepted") }
        catch { precondition(failControl.closed && failTransfer.closed && failed.opened == 2) }

        let shrinkControl = FixtureChannel(["ok\n", "ok\n", "ok\n", "ok\n"])
        let shrinkTransfer = FixtureChannel(["ok\n"])
        shrinkTransfer.beforeWrite = { index in
            if index == 1 {
                let output = try FileHandle(forWritingTo: source)
                defer { try? output.close() }
                try output.truncate(atOffset: 4096)
            }
        }
        let shrinking = FixtureConnections([shrinkControl, shrinkTransfer])
        let changed = try FlashforgeTCPClient(address: "printer.local", makeChannel: { shrinking.next() }, waitForSave: { preconditionFailure("Changed file reached save") })
        do { _ = try await changed.upload(source: source, klipper: false); preconditionFailure("Truncated source accepted") }
        catch FlashforgeTCPError.fileChanged { precondition(shrinkTransfer.closed && shrinking.opened == 2) }

        let cancelChannel = FixtureChannel(["ok\n"])
        cancelChannel.beforeWrite = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let canceled = try FlashforgeTCPClient(address: "printer.local", makeChannel: { cancelChannel })
        let task = Task { try await canceled.connect(klipper: false) }
        do { _ = try await task.value; preconditionFailure("Canceled command completed") }
        catch is CancellationError { precondition(cancelChannel.closed) }
        try Data().write(to: source)
        let empty = try FlashforgeTCPClient(address: "printer.local", makeChannel: { preconditionFailure("Empty file opened a connection") })
        do { _ = try await empty.upload(source: source, klipper: false); preconditionFailure("Empty file accepted") }
        catch FlashforgeError.emptyFile {}
        print("PASS: Flashforge TCP injected command, binary-transfer, failure and cancellation fixtures")

        // Exercise Foundation's actual TCP stream API against an independently
        // implemented loopback peer, including orderly close before M29/start.
        precondition(CommandLine.arguments.count == 2)
        let loopbackSource = directory.appendingPathComponent("loopback.gcode")
        try bytes.write(to: loopbackSource)
        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", CommandLine.arguments[1], loopbackSource.path]
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        try output.fileHandleForWriting.close()
        // FileHandle may wait for the whole requested length on a pipe. Read
        // the delimited port rather than waiting for bytes the peer never sends.
        var portLine = Data()
        while portLine.last != 10 {
            let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
            guard !byte.isEmpty, portLine.count < 8 else { throw FlashforgeTCPError.response }
            portLine.append(byte)
        }
        guard let port = Int(String(decoding: portLine, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FlashforgeTCPError.response
        }
        let live = try FlashforgeTCPClient(address: "tcp://127.0.0.1:\(port)", waitForSave: {})
        let liveJob = try await live.upload(source: loopbackSource, klipper: false)
        try await live.start(liveJob)
        server.waitUntilExit()
        precondition(server.terminationStatus == 0)
        print("PASS: Flashforge TCP fragmented acknowledgements, native command/connection order, exact bounded binary upload, separate start, failure/EOF/size/cancellation handling")
    }
}
