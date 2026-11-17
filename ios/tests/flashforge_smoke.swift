import Foundation

private final class FlashforgeFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw FlashforgeError.response }
            let (status, body) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw FlashforgeError.response }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@main
struct FlashforgeSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlashforgeFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try FlashforgeClient(address: "http://192.0.2.1", serial: "fixture-serial", code: "fixture-code", session: session)
        precondition(client.baseURL.port == 8898)
        for model in ["Flashforge AD5X", "FLASHFORGE AD5X", "Flashforge AD5X "] {
            precondition(FlashforgeClient.profileMatches(printerModel: model, modelID: 38))
            precondition(!FlashforgeClient.profileMatches(printerModel: model, modelID: 35))
        }
        for model in ["Flashforge Adventurer 5M", "Flashforge Adventurer 5M Pro", "Flashforge AD5M"] {
            precondition(FlashforgeClient.profileMatches(printerModel: model, modelID: 35))
            precondition(FlashforgeClient.profileMatches(printerModel: model, modelID: 36))
            precondition(!FlashforgeClient.profileMatches(printerModel: model, modelID: 38))
        }
        precondition(FlashforgeClient.profileMatches(printerModel: "Flashforge Creator 5"))
        for model in ["", "Voron 2.4", "Bambu Lab A1", "My AD5X preset"] {
            precondition(!FlashforgeClient.profileMatches(printerModel: model))
        }
        FlashforgeFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/detail" && request.httpMethod == "POST")
            let body = try jsonBody(request)
            precondition(body["serialNumber"] as? String == "fixture-serial" && body["checkCode"] as? String == "fixture-code")
            return (200, Data(##"{"code":0,"detail":{"pid":"0026","name":"AD5X","status":"printing","printProgress":"0.25","rightTemp":205,"rightTargetTemp":"210","platTemp":59,"platTargetTemp":60,"hasMatlStation":"1","matlStationInfo":{"slotInfos":[{"slotId":"1","hasFilament":true,"materialName":"PLA","materialColor":"#FF0000;0"},{"slotId":2,"hasFilament":1,"materialName":"PETG","materialColor":"#00FF00"},{"slotId":2,"hasFilament":true},{"slotId":4,"hasFilament":false}]}}}"##.utf8))
        }
        let status = try await client.detail()
        precondition(status.modelID == 38 && status.progress == 0.25 && status.nozzleTarget == 210)
        precondition(status.hasMaterialStation && status.slots.count == 3 && status.slots[0].color == "#FF0000")
        let fiveM = try FlashforgeClient.status(FlashforgeClient.response(Data(##"{"err":0,"detail":{"pid":"0023","name":"5M","status":"ready","printProgress":0}}"##.utf8), status: 200))
        precondition(fiveM.modelID == 35 && !fiveM.hasMaterialStation && fiveM.slots.isEmpty)
        let source = directory.appendingPathComponent("two colors.gcode")
        // Comments mentioning tools must not create extra mappings.
        let gcode = "; T3 unused\nT0\nG1 X1 E1\nT1 ; second material\nG1 X2 E2\n"
        try gcode.write(to: source, atomically: true, encoding: .utf8)
        let upload = try client.prepareUpload(source: source, leveling: true, useStation: true, slots: status.slots, toolSlots: [2, 1, 3, 4])
        precondition(upload.job.filename == "two_colors.gcode" && upload.job.mappings.map(\.slotId) == [2, 1])
        precondition(upload.request.value(forHTTPHeaderField: "printNow") == "false")
        precondition(upload.request.value(forHTTPHeaderField: "fileSize") == String(gcode.utf8.count))
        precondition(upload.request.value(forHTTPHeaderField: "gcodeToolCnt") == "2")
        let mappingData = Data(base64Encoded: upload.request.value(forHTTPHeaderField: "materialMappings")!)!
        let mappings = try JSONDecoder().decode([FlashforgeMaterialMapping].self, from: mappingData)
        precondition(mappings.map(\.toolId) == [0, 1])
        let multipart = String(decoding: try Data(contentsOf: upload.body), as: UTF8.self)
        precondition(multipart.contains("name=\"gcodeFile\"") && multipart.contains(gcode))
        FlashforgeFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/uploadGcode" && request.value(forHTTPHeaderField: "checkCode") == "fixture-code")
            precondition(request.value(forHTTPHeaderField: "printNow") == "false")
            return (200, Data(##"{"code":0,"message":"success"}"##.utf8))
        }
        let uploaded = try await client.upload(upload)
        precondition(!FileManager.default.fileExists(atPath: upload.body.path))
        FlashforgeFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/printGcode")
            let body = try jsonBody(request)
            precondition(body["fileName"] as? String == "two_colors.gcode" && body["useMatlStation"] as? Bool == true)
            precondition((body["materialMappings"] as? [[String: Any]])?.count == 2)
            return (200, Data(##"{"code":0}"##.utf8))
        }
        try await client.start(uploaded)
        FlashforgeFixtureProtocol.handler = { request in
            precondition(request.url!.path == "/control")
            let body = try jsonBody(request)
            let payload = body["payload"] as! [String: Any]
            precondition(payload["cmd"] as? String == "jobCtl_cmd")
            precondition((payload["args"] as? [String: String])?["action"] == "cancel")
            return (200, Data(##"{"code":0}"##.utf8))
        }
        try await client.cancel()
        do { _ = try client.prepareUpload(source: source, leveling: true, useStation: false, slots: [], toolSlots: []); preconditionFailure("Multi-tool job accepted without IFS") }
        catch FlashforgeError.unsupportedTools {}
        do { _ = try client.prepareUpload(source: source, leveling: true, useStation: true, slots: status.slots, toolSlots: [4, 1, 2, 3]); preconditionFailure("Empty IFS slot accepted") }
        catch FlashforgeError.materialMapping {}
        for body in [#"{"code":9}"#, #"{"code":"NaN"}"#, #"{"code":1e100}"#, "{}", "not json"] {
            do { _ = try FlashforgeClient.response(Data(body.utf8), status: 200); preconditionFailure("Invalid response accepted") }
            catch {}
        }
        print("PASS: Flashforge AD5X/5M hardware profile matching, status, credentials, IFS mappings, multipart upload, explicit start/cancel and invalid response handling")
    }
}
