import Foundation
import PolyLog
import Synchronization

// MARK: - LocalLog

/// Existing stderr/file sinks, kept separate from PolyLog's process-wide remote delivery.
enum LocalLog {
    static let verbose: Mutex<Bool> = .init(false)

    /// Optional file sink. The headless Windows build has no stderr, so without this every log line
    /// is silently dropped. Guarded so the poll, receive, and discovery threads never interleave
    /// partial lines.
    private static let fileSink: Mutex<FileHandle?> = .init(nil)

    /// Opens (creating if needed) a log file at a per-platform default location so headless runs
    /// still leave a trace. Best-effort: on failure we simply keep stderr-only. Returns the path in
    /// use, for logging back to the user.
    @discardableResult
    static func startFileLogging() -> String? {
        let url = self.defaultLogFileURL()
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            if !fm.fileExists(atPath: url.path) {
                _ = fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            self.fileSink.withLock { $0 = handle }
            return url.path
        } catch {
            return nil
        }
    }

    static func write(_ message: String, level: PolyLogLevel = .info) {
        guard level != .debug || self.verbose.withLock({ $0 }) else { return }
        let stamp = self.timestamp()
        let label = level == .warning ? "WARN" : level.rawValue.uppercased()
        let line = Data("\(stamp) [\(label)] \(message)\n".utf8)
        // Use the throwing variant with try? so we no-op instead of trapping when there is no valid
        // stderr (e.g. the headless Windows GUI-subsystem build).
        try? FileHandle.standardError.write(contentsOf: line)
        self.fileSink.withLock { handle in
            try? handle?.write(contentsOf: line)
        }
    }

    private static func defaultLogFileURL() -> URL {
        #if os(Windows)
            let env = ProcessInfo.processInfo.environment
            let base = env["LOCALAPPDATA"] ?? env["TEMP"] ?? "."
            return URL(fileURLWithPath: base)
                .appendingPathComponent("Swiftboard")
                .appendingPathComponent("swiftboard.log")
        #else
            return FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/swiftboard.log")
        #endif // os(Windows)
    }

    private static func timestamp() -> String {
        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: now)
    }
}

/// FNV-1a 64-bit. Not cryptographic, but stable and identical across platforms, which is all we
/// need to detect "did the clipboard content change" and to deduplicate. Returns a zero-padded
/// 16-char hex string.
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
