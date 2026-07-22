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

        let backend = ClipboardBackendFactory.make()
        let port = config.port
        // JSON + base64 inflate an image payload by roughly 1.4x; leave headroom.
        let maxFrameBytes = config.maxSizeBytes * 2 + 4096

        let registry = PeerRegistry()
        if let staticPeer = config.peerHost {
            registry.setStatic(staticPeer)
            Log.info("Using static peer \(staticPeer):\(port).")
        } else {
            Discovery.start(port: port, registry: registry)
        }

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

        Thread.detachNewThread {
            Transport.runServer(port: port, maxFrameBytes: maxFrameBytes) { data in
                guard let item = try? JSONDecoder().decode(ClipboardItem.self, from: data) else {
                    Log.warn("Received a frame that could not be decoded.")
                    return
                }
                engine.applyRemote(item)
            }
        }

        Log.info(
            "Swiftboard started on port \(port), images \(config.syncImages ? "on" : "off"). Press Ctrl+C to stop.",
        )

        let interval = Double(config.pollIntervalMS) / 1000.0
        while true {
            engine.pollLocal()
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
