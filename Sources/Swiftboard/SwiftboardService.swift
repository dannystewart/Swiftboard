import Foundation

// MARK: - SwiftboardServiceError

enum SwiftboardServiceError: Error, CustomStringConvertible {
    case listener(UInt16)
    case discovery

    var description: String {
        switch self {
        case let .listener(port):
            "Failed to bind TCP port \(port). Another instance or application may be using it."
        case .discovery:
            "Auto-discovery initialization failed."
        }
    }
}

// MARK: - SwiftboardService

/// Owns the long-running clipboard sync workers shared by the CLI and macOS app.
final class SwiftboardService {
    private let engine: SyncEngine

    init(config: Config) throws {
        let port = config.port
        guard let listener = Transport.makeListener(port: port) else {
            throw SwiftboardServiceError.listener(port)
        }
        Log.info("Listening for peer clipboard updates on port \(port).")

        let registry = PeerRegistry()
        if let staticPeer = config.peerHost {
            registry.setStatic(staticPeer)
            Log.info("Using static peer \(staticPeer):\(port).")
        } else if !Discovery.start(port: port, registry: registry) {
            throw SwiftboardServiceError.discovery
        }

        let backend = ClipboardBackendFactory.make()
        let engine = SyncEngine(backend: backend, config: config) { item in
            guard let host = registry.current() else {
                Log.debug("No peer known yet; holding clipboard update.")
                return
            }
            guard let payload = ClipboardWireFormat.encode(item) else {
                Log.warn("Failed to encode clipboard item; not sending.")
                return
            }
            Thread.detachNewThread {
                Transport.sendFrame(to: host, port: port, payload: payload)
            }
        }
        self.engine = engine

        Log.info("Swiftboard ready on port \(port), images \(config.syncImages ? "on" : "off").")

        let interval = Double(config.pollIntervalMS) / 1000.0
        Thread.detachNewThread {
            while true {
                engine.pollLocal()
                Thread.sleep(forTimeInterval: interval)
            }
        }

        Thread.detachNewThread {
            Transport.runServer(listener: listener, maxFrameBytes: config.maxFrameBytes) { data, peerHost in
                #if os(macOS)
                    let processingStarted = ProcessInfo.processInfo.systemUptime
                #endif
                guard let item = ClipboardWireFormat.decode(data, maxImageBytes: config.maxSizeBytes) else {
                    Log.warn("Received a frame that could not be decoded.")
                    return
                }
                // An incoming update identifies the peer even if its UDP discovery beacons cannot
                // reach us. Never replace an explicitly configured peer.
                if config.peerHost == nil {
                    switch registry.markSeen(peerHost) {
                    case .discovered:
                        Log.info("Learned peer at \(peerHost) from incoming TCP update.")
                    case .reconnected:
                        Log.info("Peer back online at \(peerHost) from incoming TCP update.")
                    case .stillPresent:
                        break
                    }
                }
                #if os(macOS)
                    let decodedAt = ProcessInfo.processInfo.systemUptime
                #endif
                engine.applyRemote(item)
                #if os(macOS)
                    if item.kind == .image {
                        let appliedAt = ProcessInfo.processInfo.systemUptime
                        Log.info(
                            "Image processing: decode \(String(format: "%.3f", decodedAt - processingStarted))s, "
                                + "clipboard write and settle \(String(format: "%.3f", appliedAt - decodedAt))s.",
                        )
                    }
                #endif // os(macOS)
            }
        }
    }
}
