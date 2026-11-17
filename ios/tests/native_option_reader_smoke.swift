import Foundation

@main
struct NativeOptionReaderSmoke {
    static func main() {
        for text in ["", String(repeating: "x", count: 4095), String(repeating: "x", count: 4096),
                     String(repeating: "; Start G-code Ω🦈\n", count: 8192)] {
            let bytes = Array(text.utf8CString)
            var attempts: [Int] = []
            let result = NativeOptionReader.read { buffer, count in
                attempts.append(count)
                guard bytes.count <= count else { return -3 }
                bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
                return 0
            }
            precondition(result == text)
            precondition(attempts.last! >= bytes.count)
            precondition(attempts.count == 1 || attempts[attempts.count - 2] < bytes.count)
        }
        for code: Int32 in [-1, -2, -4, -5] {
            var calls = 0
            let result = NativeOptionReader.read { _, _ in calls += 1; return code }
            precondition(result == nil && calls == 1)
        }
        let unterminated = NativeOptionReader.read { buffer, count in
            buffer.update(repeating: 65, count: count)
            return 0
        }
        precondition(unterminated == nil)
        print("PASS: long native option values, exact terminator boundary, Unicode, non-size errors and invalid termination")
    }
}
