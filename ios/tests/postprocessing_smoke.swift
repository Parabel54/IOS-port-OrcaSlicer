import Foundation
import CryptoKit

@main
struct PostprocessingSmoke {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cases.json"))) as! [[String: String]]
        for test in cases {
            let name = test["name"]!
            let input = directory.appendingPathComponent(name + ".input")
            let expected = try Data(contentsOf: directory.appendingPathComponent(name + ".expected"))
            try NativePostProcessing.run(file: input, commands: [test["command"]!])
            let actual = try Data(contentsOf: input)
            guard actual == expected else { fatalError("Upstream Zmod parity failed: \(name)\n\(String(decoding: actual, as: UTF8.self))\nEXPECTED\n\(String(decoding: expected, as: UTF8.self))") }
            try NativePostProcessing.run(file: input, commands: [test["command"]!])
            let repeated = try Data(contentsOf: input)
            precondition(repeated == expected, "Zmod must be idempotent")
            let newline = actual.firstIndex(of: 10)!
            let hash = Insecure.MD5.hash(data: actual[(newline + 1)...]).map { String(format: "%02x", $0) }.joined()
            precondition(String(decoding: actual[..<newline], as: UTF8.self) == "; MD5:" + hash)
        }
        let path = #""C:\Python\python.exe" "C:\scripts\zmod-preprocess.py" --no-simplify-objects"#
        let serialized = NativePostProcessing.serializeCommands([path, "zmod-preprocess.py"])
        let jsonList = "[" + serialized.replacingOccurrences(of: ";", with: ",") + "]"
        let roundTrip = try JSONDecoder().decode([String].self, from: Data(jsonList.utf8))
        precondition(roundTrip == [path, "zmod-preprocess.py"])
        let resolved = try NativePostProcessing.resolve(path)
        precondition(resolved.simplify == false)
        for command in ["unknown.py", "zmod-preprocess.sh", "zmod-preprocess.py --invalid", "zmod-preprocess.py --simplify-objects -1", "zmod-preprocess.py ; echo bad"] {
            do { _ = try NativePostProcessing.resolve(command); fatalError("Accepted unsupported command") }
            catch {}
        }
        let protectedFile = directory.appendingPathComponent("cancelled.gcode")
        let original = Data("G28\n".utf8)
        try original.write(to: protectedFile)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try NativePostProcessing.run(file: protectedFile, commands: ["zmod-preprocess.py"])
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let respectedCancellation = await cancelled.value
        let unchanged = try Data(contentsOf: protectedFile)
        precondition(respectedCancellation && unchanged == original)
        print("PASS: \(cases.count) upstream Zmod byte-for-byte cases, checksum, idempotence and command validation")
    }
}
