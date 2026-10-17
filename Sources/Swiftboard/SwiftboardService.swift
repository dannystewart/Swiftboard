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
        let outgoing = TransferQueue()
        let engine = SyncEngine(backend: backend, config: config) { item in
            outgoing.enqueue(item)
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
            while true {
                outgoing.waitForWork()
                let delivered = outgoing.deliverNext { entry in
                    guard let host = registry.current(), let payload = entry.payload else { return false }
                    return Transport.sendFrame(to: host, port: port, payload: payload)
                }
                // Retry the same head after failures, without tying up clipboard capture.
                if !delivered { Thread.sleep(forTimeInterval: 1.0) }
            }
        }

        Thread.detachNewThread {
            var receiver = TransferReceiver()
            Transport.runServer(listener: listener, maxFrameBytes: config.maxFrameBytes) { data, peerHost in
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
                return receiver.receive(data, maxBytes: config.maxSizeBytes) { item in
                    guard engine.applyRemote(item) else { return false }
                    // Keep this item on the clipboard before allowing the next transfer. The
                    // state lock is released so local copies can still be captured during this gap.
                    Thread.sleep(forTimeInterval: 0.5)
                    return true
                }
            }
        }
    }
}
