import AppKit
import PolyLog

// MARK: - SwiftboardApp

@main
enum SwiftboardApp {
    static func main() {
        var config = Config()
        if let peer = UserDefaults.standard.string(forKey: "peer"), !peer.isEmpty {
            config.peerHost = peer
        }

        SwiftboardLogging.start()
        logger.info("Swiftboard app starting (PID \(ProcessInfo.processInfo.processIdentifier)).")

        do {
            _ = try SwiftboardService(config: config)
        } catch {
            logger.error("\(error) Exiting for launchd restart.")
            Task {
                await SwiftboardLogging.shutdown()
                exit(1)
            }
            RunLoop.main.run()
            return
        }

        let application = NSApplication.shared
        let delegate = SwiftboardAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

// MARK: - SwiftboardAppDelegate

@MainActor
private final class SwiftboardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await SwiftboardLogging.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
