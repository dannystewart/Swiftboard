import Foundation
import Synchronization

#if os(Windows)
    import WinSDK
#else
    import Darwin
#endif

// MARK: - PeerRegistry

/// What a fresh beacon told us about the peer, so callers can log transitions.
enum PeerEvent: Sendable, Equatable {
    case discovered // first sighting, or the peer's IP changed
    case reconnected // a peer we'd marked offline is back
    case stillPresent // routine heartbeat, nothing to announce
}

/// Holds the current peer address and liveness. The send path reads `current()`
/// live, so a peer that is discovered (or whose IP changes) is picked up without
/// a restart. Beacons double as a heartbeat: `markSeen` refreshes last-seen and
/// a watchdog calls `markStaleIfNeeded` to notice when they stop arriving.
final class PeerRegistry: Sendable {
    private struct State {
        var host: String?
        var lastSeen: Date?
        var online = false
    }

    private let state: Mutex<State> = .init(State())

    func current() -> String? {
        self.state.withLock { $0.host }
    }

    /// Seed a peer supplied on the command line (static mode, no beacons).
    func setStatic(_ host: String) {
        self.state.withLock { state in
            state.host = host
            state.online = true
        }
    }

    /// Record a beacon from `host` and report whether it's worth announcing.
    func markSeen(_ host: String) -> PeerEvent {
        self.state.withLock { state in
            let event: PeerEvent
            if state.host != host {
                event = .discovered
            } else if !state.online {
                event = .reconnected
            } else {
                event = .stillPresent
            }
            state.host = host
            state.lastSeen = Date()
            state.online = true
            return event
        }
    }

    /// Returns true exactly once, when the peer transitions to offline.
    func markStaleIfNeeded(timeout: TimeInterval) -> Bool {
        self.state.withLock { state in
            guard state.online, let last = state.lastSeen,
                  Date().timeIntervalSince(last) > timeout
            else {
                return false
            }
            state.online = false
            return true
        }
    }
}

// MARK: - Discovery

/// UDP broadcast peer discovery. Each instance periodically shouts a beacon
/// carrying a per-run UUID and listens for the other's shout; a beacon with a
/// different UUID reveals the peer's IP (read from the source address).
enum Discovery {
    private static let beaconPrefix = "SWIFTBOARD/1 "
    private static let interval: TimeInterval = 3

    static func start(port: UInt16, registry: PeerRegistry) {
        Sock.prepare()
        let myID = UUID().uuidString

        guard let fd = makeSocket(port: port) else {
            Log.error("Discovery socket setup failed; auto-discovery unavailable. Pass a peer address instead.")
            return
        }

        Log.info("Auto-discovery active: broadcasting on UDP port \(port).")
        Thread.detachNewThread { self.listenLoop(fd: fd, myID: myID, registry: registry) }
        Thread.detachNewThread { self.broadcastLoop(fd: fd, port: port, myID: myID) }
        Thread.detachNewThread { self.livenessLoop(registry: registry) }
    }

    // MARK: - Liveness watchdog

    /// Missing this many seconds of beacons (~3 intervals) means the peer is gone.
    private static let livenessTimeout: TimeInterval = 10

    private static func livenessLoop(registry: PeerRegistry) {
        while true {
            Thread.sleep(forTimeInterval: 2)
            if registry.markStaleIfNeeded(timeout: self.livenessTimeout) {
                Log.info("Peer went offline (no beacon for \(Int(self.livenessTimeout))s).")
            }
        }
    }

    private static func makeSocket(port: UInt16) -> SocketFD? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sock.dgram
        hints.ai_flags = AI_PASSIVE

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(nil, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd != invalidSocketFD else { return nil }

        Sock.enableBoolOption(fd, SO_REUSEADDR)
        Sock.enableBoolOption(fd, SO_BROADCAST)

        guard bind(fd, info.pointee.ai_addr, Sock.addrLen(info.pointee.ai_addrlen)) == 0 else {
            Sock.close(fd)
            return nil
        }
        return fd
    }

    // MARK: - Broadcasting

    private static func broadcastLoop(fd: SocketFD, port: UInt16, myID: String) {
        guard let dest = resolveBroadcast(port: port) else {
            Log.warn("Could not resolve broadcast address; discovery beacons disabled.")
            return
        }
        let message = Array((beaconPrefix + myID).utf8)
        while true {
            self.sendBeacon(fd: fd, message: message, dest: dest)
            Thread.sleep(forTimeInterval: self.interval)
        }
    }

    /// Resolve 255.255.255.255:port once and keep the raw sockaddr bytes to reuse.
    private static func resolveBroadcast(port: UInt16) -> (bytes: [UInt8], len: Int)? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sock.dgram

        var result: UnsafeMutablePointer<addrinfo>?
        guard
            getaddrinfo("255.255.255.255", String(port), &hints, &result) == 0,
            let info = result, let addr = info.pointee.ai_addr else
        {
            return nil
        }
        defer { freeaddrinfo(result) }

        let len = Int(info.pointee.ai_addrlen)
        var bytes = [UInt8](repeating: 0, count: len)
        bytes.withUnsafeMutableBytes { raw in
            raw.baseAddress!.copyMemory(from: UnsafeRawPointer(addr), byteCount: len)
        }
        return (bytes, len)
    }

    private static func sendBeacon(fd: SocketFD, message: [UInt8], dest: (bytes: [UInt8], len: Int)) {
        dest.bytes.withUnsafeBytes { addrRaw in
            let sa = addrRaw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            message.withUnsafeBytes { msgRaw in
                #if os(Windows)
                    _ = sendto(fd, msgRaw.baseAddress!.assumingMemoryBound(to: CChar.self),
                               Int32(msgRaw.count), 0, sa, Int32(dest.len))
                #else
                    _ = sendto(fd, msgRaw.baseAddress, msgRaw.count, 0, sa, socklen_t(dest.len))
                #endif
            }
        }
    }

    // MARK: - Listening

    private static func listenLoop(fd: SocketFD, myID: String, registry: PeerRegistry) {
        while true {
            var buffer = [UInt8](repeating: 0, count: 512)
            var from = [UInt8](repeating: 0, count: 128) // room for sockaddr_storage
            let received = self.receive(fd: fd, buffer: &buffer, from: &from)
            guard received > 0 else {
                Thread.sleep(forTimeInterval: 0.5) // avoid a hot loop on errors
                continue
            }

            let text = String(decoding: buffer[0 ..< received], as: UTF8.self)
            guard text.hasPrefix(self.beaconPrefix) else { continue }
            let theirID = String(text.dropFirst(self.beaconPrefix.count))
            if theirID == myID { continue } // our own broadcast echoing back

            // The IPv4 address sits at byte offset 4 of the sockaddr on both
            // platforms: Darwin's sin_len + sin_family (1+1) occupies the same
            // two bytes as the 2-byte sin_family elsewhere, and sin_port is next.
            let ip = "\(from[4]).\(from[5]).\(from[6]).\(from[7])"
            switch registry.markSeen(ip) {
            case .discovered:
                Log.info("Discovered peer at \(ip).")
            case .reconnected:
                Log.info("Peer back online at \(ip).")
            case .stillPresent:
                Log.debug("Heartbeat from \(ip).")
            }
        }
    }

    private static func receive(fd: SocketFD, buffer: inout [UInt8], from: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { bufRaw in
            from.withUnsafeMutableBytes { fromRaw in
                let sa = fromRaw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                #if os(Windows)
                    var fromLen = Int32(fromRaw.count)
                    let n = recvfrom(fd, bufRaw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                     Int32(bufRaw.count), 0, sa, &fromLen)
                #else
                    var fromLen = socklen_t(fromRaw.count)
                    let n = recvfrom(fd, bufRaw.baseAddress, bufRaw.count, 0, sa, &fromLen)
                #endif
                return Int(n)
            }
        }
    }
}
