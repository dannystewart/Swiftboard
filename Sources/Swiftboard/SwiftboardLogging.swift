import Foundation
import PolyLog
import Synchronization

/// All app events use this logger. Its observer preserves Swiftboard's existing local output.
nonisolated let logger: PolyLog = {
    let logger = PolyLog(localOutput: false)
    logger.onLogEntry = { entry in
        LocalLog.write(entry.message, level: entry.level)
    }
    return logger
}()

// MARK: - SwiftboardLogging

/// Opt-in remote delivery for both Debug and Release, configured outside the executable.
enum SwiftboardLogging {
    private struct Settings: Decodable {
        let enabled: Bool
        let serverURL: URL
        let publishableKey: String
        let ingestToken: String
    }

    static func start(verbose: Bool = false) {
        LocalLog.verbose.withLock { $0 = verbose }
        let logPath = LocalLog.startFileLogging()
        _ = logger
        do {
            #if os(Windows)
                guard
                    let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"],
                    !base.isEmpty else
                {
                    throw CocoaError(.fileNoSuchFile)
                }
                let directory = URL(fileURLWithPath: base)
                    .appendingPathComponent("Swiftboard", isDirectory: true)
                let osName = "Windows"
            #else
                let directory = FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Swiftboard", isDirectory: true)
                let osName = "macOS"
            #endif // os(Windows)
            let config = directory.appendingPathComponent("polylog.json")
            if FileManager.default.fileExists(atPath: config.path) {
                let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: config))
                if settings.enabled {
                    let identity = try LogIdentity(
                        appBundleID: "com.dannystewart.swiftboard",
                        deviceID: self.installationID(in: directory),
                        deviceName: ProcessInfo.processInfo.hostName,
                        osName: osName,
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    )
                    try PolyLogRemote.shared.configure(PolyLogConfiguration(
                        serverURL: settings.serverURL,
                        publishableKey: settings.publishableKey,
                        ingestToken: settings.ingestToken,
                        identity: identity,
                        journalDirectory: directory.appendingPathComponent("PolyLog", isDirectory: true),
                    ))
                }
            }
        } catch {
            // Decoding/configuration errors may contain credentials. Never interpolate them.
            LocalLog.write("PolyLog could not start: check polylog.json, installation identity, and journal ownership. Local logging remains enabled.", level: .warning)
        }
        if let logPath { logger.info("Logging to \(logPath).") }
    }

    static func shutdown() async {
        _ = await PolyLogRemote.shared.shutdown(timeout: 1)
    }

    /// Only for synchronous CLI exit, never the Mac application's main actor.
    static func shutdownAndWait() {
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await self.shutdown()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 1.5)
    }

    /// A logging-only installation identity; discovery's per-process UUID is intentionally
    /// separate.
    private static func installationID(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("installation-id")
        if FileManager.default.fileExists(atPath: url.path) {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: value) != nil else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        let value = UUID().uuidString
        // Exclusive creation avoids replacing another process's identity during concurrent startup.
        do {
            try Data(value.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            let existing = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: existing) != nil else { throw CocoaError(.fileReadCorruptFile) }
            return existing
        }
        return value
    }
}
