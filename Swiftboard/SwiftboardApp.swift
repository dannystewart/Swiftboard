import AppKit

@main
enum SwiftboardApp {
    static func main() {
        var config = Config()
        if let peer = UserDefaults.standard.string(forKey: "peer"), !peer.isEmpty {
            config.peerHost = peer
        }

        if let logPath = Log.startFileLogging() {
            Log.info("Logging to \(logPath).")
        }
        Log.info("Swiftboard app starting (PID \(ProcessInfo.processInfo.processIdentifier)).")

        do {
            _ = try SwiftboardService(config: config)
        } catch {
            Log.error("\(error) Exiting for launchd restart.")
            exit(1)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
