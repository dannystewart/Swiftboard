import Foundation

@main
struct Swiftboard {
    static func main() {
        let config: Config
        do {
            guard let parsed = try ArgParser.parse(CommandLine.arguments) else {
                print(Config.usage)
                return
            }
            config = parsed
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n\(Config.usage)\n".utf8))
            exit(2)
        }

        if config.verbose {
            Log.minLevel = .debug
        }

        // Do this first: the headless Windows build has no console, so the file
        // is the only place logs can land.
        if let logPath = Log.startFileLogging() {
            Log.info("Logging to \(logPath).")
        }
        Log.info("Swiftboard process starting (PID \(ProcessInfo.processInfo.processIdentifier)).")

        let port = config.port
        // JSON + base64 inflate an image payload by roughly 1.4x; leave headroom.
        let maxFrameBytes = config.maxSizeBytes * 2 + 4096
        guard let listener = Transport.makeListener(port: port) else {
            Log.error("Failed to bind TCP port \(port). Another instance or application may be using it; exiting for supervisor restart.")
            exit(1)
        }
        Log.info("Listening for peer clipboard updates on port \(port).")

        let registry = PeerRegistry()
        if let staticPeer = config.peerHost {
            registry.setStatic(staticPeer)
            Log.info("Using static peer \(staticPeer):\(port).")
        } else {
            guard Discovery.start(port: port, registry: registry) else {
                Log.error("Auto-discovery initialization failed; exiting for supervisor restart.")
                exit(1)
            }
        }

        let backend = ClipboardBackendFactory.make()
        let engine = SyncEngine(backend: backend, config: config) { item in
            guard let host = registry.current() else {
                Log.debug("No peer known yet; holding clipboard update.")
                return
            }
            guard let payload = try? JSONEncoder().encode(item) else {
                Log.warn("Failed to encode clipboard item; not sending.")
                return
            }
            // Send off the poll thread so an unreachable peer never stalls polling.
            Thread.detachNewThread {
                Transport.sendFrame(to: host, port: port, payload: payload)
            }
        }

        Log.info("Swiftboard ready on port \(port), images \(config.syncImages ? "on" : "off").")

        let interval = Double(config.pollIntervalMS) / 1000.0
        Thread.detachNewThread {
            while true {
                engine.pollLocal()
                Thread.sleep(forTimeInterval: interval)
            }
        }

        self.runServer(listener: listener, maxFrameBytes: maxFrameBytes, engine: engine)
    }

    private static func runServer(listener: SocketFD, maxFrameBytes: Int, engine: SyncEngine) {
        Transport.runServer(listener: listener, maxFrameBytes: maxFrameBytes) { data in
            guard let item = try? JSONDecoder().decode(ClipboardItem.self, from: data) else {
                Log.warn("Received a frame that could not be decoded.")
                return
            }
            engine.applyRemote(item)
        }
    }
}
