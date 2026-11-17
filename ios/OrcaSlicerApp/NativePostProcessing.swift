// Native adaptation of ghzserg/zmod_preprocess/zmod-preprocess.py.
// Original: (C) Namida Verasche aka ninjamida; MD5 portions from addMD5.py.
// Modified for iOS: streaming IO, CryptoKit, native command resolution.
// Apache-2.0; see ios/licenses/zmod-preprocess-Apache-2.0.txt.
import Foundation
import CoreFoundation
import CryptoKit

/// In-process G-code hooks. Desktop command lines are resolved to known native
/// implementations; no shell command is executed and unknown hooks fail closed.
enum NativePostProcessing {
    struct ZmodOptions {
        var simplify = true
        var tolerance = 0.2
    }
    enum Failure: LocalizedError {
        case unsupported(String)
        case invalidOptions
        var errorDescription: String? {
            switch self {
            case .unsupported(let command): return "This post-processing script has no iOS implementation: \(command)"
            case .invalidOptions: return "Invalid Zmod post-processing arguments."
            }
        }
    }

    /// The editor uses ordinary commands; the C ABI stores Orca's quoted list.
    static func serializeCommands(_ commands: [String]) -> String {
        commands.map { command in
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"" + escaped + "\""
        }.joined(separator: ";")
    }

    static func resolve(_ command: String) throws -> ZmodOptions {
        let pattern = #""([^"]*)"|'([^']*)'|([^\s]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = command as NSString
        let tokens = regex.matches(in: command, range: NSRange(location: 0, length: ns.length)).map { match in
            (1...3).first(where: { match.range(at: $0).location != NSNotFound }).map { ns.substring(with: match.range(at: $0)) } ?? ""
        }
        func basename(_ token: String) -> String { token.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? token }
        let names = ["zmod-preprocess.py", "zmod_preprocess", "zmod_preprocess-windows-amd64.exe", "zmod_preprocess-linux-amd64", "zmod_preprocess-darwin-arm64", "zmod_preprocess-darwin-amd64"]
        var index = 0
        if let first = tokens.first, ["python", "python3", "python.exe", "python3.exe", "bash", "sh"].contains(basename(first).lowercased()) { index += 1 }
        guard index < tokens.count, names.contains(basename(tokens[index])) else { throw Failure.unsupported(command) }
        index += 1
        var result = ZmodOptions()
        while index < tokens.count {
            let argument = tokens[index]
            if argument.hasPrefix("--simplify-objects=") || argument.hasPrefix("-simplify-objects=") {
                guard let equals = argument.firstIndex(of: "="), let value = Double(argument[argument.index(after: equals)...]), value.isFinite, value >= 0 else { throw Failure.invalidOptions }
                result.tolerance = value
                index += 1
                continue
            }
            switch argument {
            case "-no-simplify-objects", "--no-simplify-objects": result.simplify = false
            case "-simplify-objects", "--simplify-objects":
                index += 1
                guard index < tokens.count, let value = Double(tokens[index]), value.isFinite, value >= 0 else { throw Failure.invalidOptions }
                result.tolerance = value
            default: throw Failure.invalidOptions
            }
            index += 1
        }
        return result
    }

    static func run(file: URL, commands: [String]) throws {
        try Task.checkCancellation()
        // Validate the whole sequence before changing any bytes.
        let options = try commands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(resolve)
        for option in options { try zmod(file: file, options: option) }
    }

    /// Matches Python text mode's universal newline translation while preserving
    /// arbitrary non-UTF8 comment bytes. Memory is bounded by the longest line.
    private static func lines(_ file: URL, visit: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var line = Data()
        var previousCR = false
        while let block = try input.read(upToCount: 65536), !block.isEmpty {
            try Task.checkCancellation()
            for byte in block {
                if previousCR && byte == 10 { previousCR = false; continue }
                previousCR = byte == 13
                if byte == 13 || byte == 10 {
                    line.append(10)
                    try visit(line)
                    line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
        }
        if !line.isEmpty { try visit(line) }
    }

    static func zmod(file: URL, options: ZmodOptions) throws {
        var tools: [Int] = []
        var colors: [String] = []
        var types: [String] = []
        var headerEnd: Int?
        var lineNumber = 0
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var skippedMD5 = false
        try lines(file) { bytes in
            let line = text(bytes)
            if lineNumber == 0 && !skippedMD5 && line.hasPrefix("; md5") { skippedMD5 = true; return }
            if line.hasPrefix("t") {
                let token = line.split(separator: ";", maxSplits: 1).first?.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let value = String(token.dropFirst())
                let digits = value.hasPrefix("+") || value.hasPrefix("-") ? String(value.dropFirst()) : value
                if !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let tool = Int(value), !tools.contains(tool) { tools.append(tool) }
            }
            func fields(_ prefix: String) -> [String]? {
                guard line.hasPrefix(prefix), let equals = line.firstIndex(of: "=") else { return nil }
                let body = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return body.isEmpty ? [] : body.components(separatedBy: ";")
            }
            if let values = fields("; filament_colour =") { colors = values }
            if let values = fields("; filament_type =") { types = values }
            if headerEnd == nil && line.hasPrefix("; header_block_end") { headerEnd = lineNumber }
            lineNumber += 1
        }
        if tools.isEmpty { tools = [0] }
        let highest = max(tools.max() ?? 0, 0)
        // Reject corrupt tool indexes instead of allocating unbounded metadata.
        guard highest <= 65535 else { throw Failure.invalidOptions }
        if colors.count <= highest { colors += Array(repeating: "", count: highest + 1 - colors.count) }
        if types.count <= highest { types += Array(repeating: "", count: highest + 1 - types.count) }
        let toolString = tools.map { String($0) }.joined(separator: ",")
        let colorString = colors.joined(separator: ",")
        let typeString = types.joined(separator: ",")
        let metadata = Data("; zmod_color_data = \(toolString)|\(colorString)|\(typeString)\n".utf8)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".gcode")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: Data(("; MD5:" + String(repeating: "0", count: 32) + "\n").utf8))
        var digest = Insecure.MD5()
        func write(_ data: Data) throws { digest.update(data: data); try output.write(contentsOf: data) }
        lineNumber = 0
        skippedMD5 = false
        var inserted = false
        try lines(file) { bytes in
            let line = text(bytes)
            if lineNumber == 0 && !skippedMD5 && line.hasPrefix("; md5") { skippedMD5 = true; return }
            if lineNumber == (headerEnd ?? 0) { try write(metadata); inserted = true }
            lineNumber += 1
            if line.hasPrefix("; zmod_color_data =") { return }
            let processed = options.simplify ? simplify(bytes, tolerance: options.tolerance) : bytes
            try write(processed)
        }
        if !inserted { try write(metadata) }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        try output.seek(toOffset: 0)
        try output.write(contentsOf: Data(("; MD5:" + hex + "\n").utf8))
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }

    private struct Point { let x: Double; let y: Double }
    private static func simplify(_ bytes: Data, tolerance: Double) -> Data {
        guard let line = String(data: bytes, encoding: .utf8), line.contains("EXCLUDE_OBJECT_DEFINE"),
              let marker = line.range(of: "POLYGON=") else { return bytes }
        var start = marker.upperBound
        while start < line.endIndex && (line[start] == " " || line[start] == "\t") { start = line.index(after: start) }
        guard start < line.endIndex, line[start] == "[" else { return bytes }
        var end = start
        var depth = 0
        repeat {
            if line[end] == "[" { depth += 1 }
            if line[end] == "]" { depth -= 1 }
            end = line.index(after: end)
        } while end < line.endIndex && depth > 0
        guard depth == 0, let raw = try? JSONSerialization.jsonObject(with: Data(line[start..<end].utf8)) as? [[NSNumber]], raw.count >= 5,
              raw.allSatisfy({ $0.count == 2 && $0.allSatisfy { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite } }) else { return bytes }
        let points = raw.map { Point(x: $0[0].doubleValue, y: $0[1].doubleValue) }
        var minX = 0, maxX = 0, minY = 0, maxY = 0
        for i in points.indices {
            if points[i].x < points[minX].x { minX = i }
            if points[i].x > points[maxX].x { maxX = i }
            if points[i].y < points[minY].y { minY = i }
            if points[i].y > points[maxY].y { maxY = i }
        }
        var result: [Point] = []
        if tolerance == 0 {
            result = [Point(x: points[minX].x, y: points[minY].y), Point(x: points[maxX].x, y: points[minY].y), Point(x: points[maxX].x, y: points[maxY].y), Point(x: points[minX].x, y: points[maxY].y)]
        } else {
            let anchors = Array(Set([minX, maxX, minY, maxY])).sorted()
            guard anchors.count >= 2 else { return bytes }
            for i in anchors.indices {
                let a = anchors[i], b = anchors[(i + 1) % anchors.count]
                let arc = b > a ? Array(points[a...b]) : Array(points[a...]) + Array(points[...b])
                result += Array(thin(arc, tolerance: tolerance).dropLast())
            }
        }
        guard result.count < points.count else { return bytes }
        func number(_ value: Double) -> String {
            // Expand Swift's shortest round-trippable representation to fixed
            // notation, matching the Python/Go Zmod implementations.
            let text = String(value)
            let pieces = text.lowercased().components(separatedBy: "e")
            var body = pieces[0]
            if pieces.count == 2, let exponent = Int(pieces[1]) {
                let negative = body.hasPrefix("-")
                if negative { body.removeFirst() }
                let parts = body.components(separatedBy: ".")
                let digits = parts.joined()
                let position = parts[0].count + exponent
                if position <= 0 { body = "0." + String(repeating: "0", count: -position) + digits }
                else if position >= digits.count { body = digits + String(repeating: "0", count: position - digits.count) }
                else { let split = digits.index(digits.startIndex, offsetBy: position); body = String(digits[..<split]) + "." + String(digits[split...]) }
                if negative { body = "-" + body }
            }
            if body.contains(".") { while body.hasSuffix("0") { body.removeLast() }; if body.hasSuffix(".") { body.removeLast() } }
            return body
        }
        let coordinates: [String] = result.map { point in "[\(number(point.x)),\(number(point.y))]" }
        let polygon = "[" + coordinates.joined(separator: ",") + "]"
        return Data((String(line[..<start]) + polygon + String(line[end...])).utf8)
    }

    private static func thin(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count >= 3 else { return points }
        var keep = Set([0, points.count - 1])
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last - first >= 2 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y
            let chord = hypot(dx, dy)
            var worst = 0.0, at = first
            for index in (first + 1)..<last {
                let p = points[index]
                let distance = chord == 0 ? hypot(p.x - a.x, p.y - a.y) : abs(dx * (a.y - p.y) - dy * (a.x - p.x)) / chord
                if distance > worst { worst = distance; at = index }
            }
            if worst > tolerance { keep.insert(at); stack.append((first, at)); stack.append((at, last)) }
        }
        return keep.sorted().map { points[$0] }
    }
}
