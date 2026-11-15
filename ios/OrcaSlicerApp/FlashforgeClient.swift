import Foundation

struct FlashforgeSlot: Identifiable, Equatable {
    let id: Int
    let hasFilament: Bool
    let material: String
    let color: String
}

struct FlashforgeStatus {
    let name: String
    let modelID: Int?
    let state: String
    let filename: String
    let progress: Double
    let nozzle: Double?
    let nozzleTarget: Double?
    let bed: Double?
    let bedTarget: Double?
    let slots: [FlashforgeSlot]
    let hasMaterialStation: Bool
}

struct FlashforgeMaterialMapping: Codable, Equatable {
    let toolId: Int
    let slotId: Int
    let materialName: String
    let toolMaterialColor: String
    let slotMaterialColor: String
}

struct FlashforgeUploadedJob {
    let filename: String
    let source: URL
    let mappings: [FlashforgeMaterialMapping]
    let leveling: Bool
}

enum FlashforgeError: LocalizedError {
    case credentials, address, response, rejected(Int), http(Int), materialMapping, unsupportedTools, emptyFile
    var errorDescription: String? {
        switch self {
        case .credentials: return String(localized: "Enter the printer’s serial number and LAN access code.")
        case .address: return String(localized: "Enter the printer’s HTTP or HTTPS address. Flashforge normally uses port 8898.")
        case .response: return String(localized: "The printer returned an invalid Flashforge response.")
        case .rejected(let code): return String(localized: "Flashforge rejected the request (code \(code)). Check the printer’s access code and screen.")
        case .http(let status): return String(localized: "Flashforge returned HTTP \(status). Check the address, network mode, and firmware.")
        case .materialMapping: return String(localized: "Connect to read the AD5X slots, then map each used tool to a loaded material slot before uploading.")
        case .unsupportedTools: return String(localized: "This G-code requires unsupported tools. Use the matching Flashforge profile; AD5X supports tools 0–3 and 5M supports one tool.")
        case .emptyFile: return String(localized: "The G-code file is empty.")
        }
    }
}

// A native implementation of the local HTTP protocol used by upstream Flashforge.cpp.
// No desktop binary plugin or cloud account is required. Redirects are rejected so
// serial numbers and access codes cannot be forwarded to a different endpoint.
struct FlashforgeClient {
    let baseURL: URL
    let serial: String
    let code: String
    private let session: URLSession

    init(address: String, serial: String, code: String, session: URLSession = .shared) throws {
        guard let url = PrinterConnection.validatedURL(address),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.isEmpty || parts.path == "/" else { throw FlashforgeError.address }
        if parts.port == nil { parts.port = 8898 }
        guard let base = parts.url else { throw FlashforgeError.address }
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty, !code.isEmpty,
              !serial.contains(where: { $0.isNewline }), !code.contains(where: { $0.isNewline }) else {
            throw FlashforgeError.credentials
        }
        self.baseURL = base
        self.serial = serial
        self.code = code
        self.session = session
    }

    func jsonRequest(_ endpoint: String, fields: [String: Any] = [:]) throws -> URLRequest {
        var body = fields
        body["serialNumber"] = serial
        body["checkCode"] = code
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func response(_ data: Data, status: Int) throws -> [String: Any] {
        guard (200...299).contains(status) else { throw FlashforgeError.http(status) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlashforgeError.response
        }
        // Firmware uses either code or err, and may encode numeric fields as strings.
        guard let value = number(object["code"]) ?? number(object["err"]), let code = Int(exactly: value) else {
            throw FlashforgeError.response
        }
        if code != 0 { throw FlashforgeError.rejected(code) }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let text = value as? String { number = Double(text.trimmingCharacters(in: .whitespaces)) }
        else { number = nil }
        guard let number, number.isFinite else { return nil }
        return number
    }

    static func status(_ object: [String: Any]) throws -> FlashforgeStatus {
        guard let detail = object["detail"] as? [String: Any], let state = detail["status"] as? String else {
            throw FlashforgeError.response
        }
        let station = (detail["matlStationInfo"] ?? detail["MatlStationInfo"]) as? [String: Any] ?? [:]
        let reported = (station["slotInfos"] ?? station["SlotInfos"]) as? [[String: Any]] ?? []
        var slotIDs = Set<Int>()
        let slots = reported.enumerated().compactMap { index, item -> FlashforgeSlot? in
            guard let id = Int(exactly: number(item["slotId"]) ?? Double(index + 1)),
                  (1...4).contains(id), slotIDs.insert(id).inserted else { return nil }
            let color = (item["materialColor"] as? String ?? "").components(separatedBy: ";")[0]
            return FlashforgeSlot(id: id, hasFilament: (number(item["hasFilament"]) ?? 0) != 0,
                                  material: item["materialName"] as? String ?? "", color: color)
        }
        let modelID: Int?
        if let value = detail["pid"] as? String { modelID = Int(value, radix: 16) }
        else { modelID = number(detail["pid"]).flatMap { Int(exactly: $0) } }
        return FlashforgeStatus(name: detail["name"] as? String ?? "Flashforge", modelID: modelID, state: state,
                                filename: detail["printFileName"] as? String ?? "",
                                progress: min(max(number(detail["printProgress"]) ?? 0, 0), 1),
                                nozzle: number(detail["rightTemp"]), nozzleTarget: number(detail["rightTargetTemp"]),
                                bed: number(detail["platTemp"]), bedTarget: number(detail["platTargetTemp"]),
                                slots: slots, hasMaterialStation: number(detail["hasMatlStation"] ?? detail["HasMatlStation"]) == 1 || !slots.isEmpty)
    }

    func detail() async throws -> FlashforgeStatus {
        try Self.status(await send(jsonRequest("detail")))
    }

    func start(_ job: FlashforgeUploadedJob) async throws {
        _ = try await send(jsonRequest("printGcode", fields: [
            "fileName": job.filename, "levelingBeforePrint": job.leveling,
            "firstLayerInspection": false, "flowCalibration": false, "timeLapseVideo": false,
            "useMatlStation": !job.mappings.isEmpty, "gcodeToolCnt": job.mappings.count,
            "materialMappings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(job.mappings))
        ]))
    }

    func cancel() async throws {
        _ = try await send(jsonRequest("control", fields: [
            "payload": ["cmd": "jobCtl_cmd", "args": ["jobID": "", "action": "cancel"]]
        ]))
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request, delegate: FlashforgeNoRedirect())
        try Task.checkCancellation()
        return try Self.response(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    struct Upload {
        let request: URLRequest
        let body: URL
        let job: FlashforgeUploadedJob
    }

    func prepareUpload(source: URL, leveling: Bool, useStation: Bool,
                       slots: [FlashforgeSlot], toolSlots: [Int]) throws -> Upload {
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("orca-flashforge-\(UUID().uuidString)")
        var keepBody = false
        defer { if !keepBody { try? FileManager.default.removeItem(at: body) } }
        guard FileManager.default.createFile(atPath: body.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: body)
        defer { try? output.close() }
        let filename = source.lastPathComponent.unicodeScalars.map { scalar -> String in
            let ascii = scalar.value
            return (48...57).contains(ascii) || (65...90).contains(ascii) || (97...122).contains(ascii) || "._-".unicodeScalars.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let boundary = "OrcaFlashforge\(UUID().uuidString)"
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"gcodeFile\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let toolCommand = try NSRegularExpression(pattern: #"^\s*(?:N\d+\s+)?T(\d+)(?:\s|;|\*|$)"#, options: [.caseInsensitive])
        var pending = Data()
        var tools = Set<Int>()
        var size = 0
        func scan(_ line: Data) throws {
            let text = String(decoding: line, as: UTF8.self)
            if let match = toolCommand.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                guard let tool = Int(text[range]), (0...3).contains(tool) else { throw FlashforgeError.unsupportedTools }
                tools.insert(tool)
            }
        }
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            size += data.count
            try output.write(contentsOf: data)
            pending.append(data)
            var lineStart = pending.startIndex
            for index in pending.indices where pending[index] == 10 {
                try scan(pending.subdata(in: lineStart..<index))
                lineStart = index + 1
            }
            pending = pending.subdata(in: lineStart..<pending.endIndex)
            guard pending.count < 1_048_576 else { throw FlashforgeError.response }
        }
        try scan(pending)
        guard size > 0 else { throw FlashforgeError.emptyFile }
        if tools.isEmpty { tools.insert(0) }
        if !useStation, tools != [0] { throw FlashforgeError.unsupportedTools }
        let mappings: [FlashforgeMaterialMapping] = try useStation ? tools.sorted().map { tool in
            guard tool < toolSlots.count, let slot = slots.first(where: { $0.id == toolSlots[tool] }),
                  slot.hasFilament, !slot.material.isEmpty else { throw FlashforgeError.materialMapping }
            return FlashforgeMaterialMapping(toolId: tool, slotId: slot.id, materialName: slot.material,
                                             toolMaterialColor: slot.color, slotMaterialColor: slot.color)
        } : []
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: baseURL.appendingPathComponent("uploadGcode"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let headers = ["serialNumber": serial, "checkCode": code, "fileSize": String(size),
                       "printNow": "false", "levelingBeforePrint": String(leveling),
                       "flowCalibration": "false", "firstLayerInspection": "false", "timeLapseVideo": "false",
                       "useMatlStation": String(useStation), "gcodeToolCnt": String(mappings.count),
                       "materialMappings": try JSONEncoder().encode(mappings).base64EncodedString(),
                       "Content-Type": "multipart/form-data; boundary=\(boundary)"]
        request.allHTTPHeaderFields = headers
        keepBody = true
        return Upload(request: request, body: body, job: FlashforgeUploadedJob(filename: filename, source: source, mappings: mappings, leveling: leveling))
    }

    func upload(_ upload: Upload) async throws -> FlashforgeUploadedJob {
        defer { try? FileManager.default.removeItem(at: upload.body) }
        let (data, response) = try await session.upload(for: upload.request, fromFile: upload.body, delegate: FlashforgeNoRedirect())
        try Task.checkCancellation()
        _ = try Self.response(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return upload.job
    }
}

private final class FlashforgeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
