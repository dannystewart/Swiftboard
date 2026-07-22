import Foundation

// MARK: - Log

/// Deliberately not using PolyKit here: this target has to compile and run on
/// Windows, so it stays dependency-free. This is a bare stderr logger instead.
enum Log {
    enum Level: Int, Sendable {
        case debug = 0
        case info
        case warn
        case error

        var label: String {
            switch self {
            case .debug: "DEBUG"
            case .info: "INFO"
            case .warn: "WARN"
            case .error: "ERROR"
            }
        }
    }

    /// Adjustable at startup via --verbose. Reads are racy but harmless.
    nonisolated(unsafe) static var minLevel: Level = .info

    static func log(_ level: Level, _ message: String) {
        guard level.rawValue >= self.minLevel.rawValue else { return }
        let stamp = self.timestamp()
        FileHandle.standardError.write(Data("\(stamp) [\(level.label)] \(message)\n".utf8))
    }

    static func debug(_ message: @autoclosure () -> String) { self.log(.debug, message()) }
    static func info(_ message: @autoclosure () -> String) { self.log(.info, message()) }
    static func warn(_ message: @autoclosure () -> String) { self.log(.warn, message()) }
    static func error(_ message: @autoclosure () -> String) { self.log(.error, message()) }

    private static func timestamp() -> String {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: now)
    }
}

/// FNV-1a 64-bit. Not cryptographic, but stable and identical across platforms,
/// which is all we need to detect "did the clipboard content change" and to
/// deduplicate. Returns a zero-padded 16-char hex string.
func contentHash(_ bytes: some Sequence<UInt8>) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    let prime: UInt64 = 0x0000_0100_0000_01B3
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* prime
    }
    var hex = String(hash, radix: 16)
    if hex.count < 16 {
        hex = String(repeating: "0", count: 16 - hex.count) + hex
    }
    return hex
}
