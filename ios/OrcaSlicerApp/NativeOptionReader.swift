import Foundation

enum NativeOptionReader {
    // Both native option readers return -3 only when the serialized value and
    // its terminator do not fit. Other failures must not trigger another read.
    static func read(_ reader: (UnsafeMutablePointer<CChar>, Int) -> Int32) -> String? {
        var capacity = 4096
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let code = buffer.withUnsafeMutableBufferPointer { reader($0.baseAddress!, $0.count) }
            if code == 0 {
                guard buffer.contains(0) else { return nil }
                return String(cString: buffer)
            }
            guard code == -3, capacity <= Int.max / 2 else { return nil }
            capacity *= 2
        }
    }
}
