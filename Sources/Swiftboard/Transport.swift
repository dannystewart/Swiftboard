import Foundation

#if os(Windows)
    import WinSDK
#else
    import Darwin
#endif

// MARK: - Transport

/// Length-prefixed framing: a 4-byte big-endian payload length followed by the
/// JSON bytes. One frame per clipboard update; the sender opens a fresh
/// connection per update and closes it, which keeps the protocol stateless.
enum Transport {
    /// Creates the listener synchronously so startup cannot report success while
    /// the receive path is unavailable. The bound socket also prevents a second
    /// Swiftboard instance from starting on the same port.
    static func makeListener(port: UInt16) -> SocketFD? {
        Sock.prepare()
        return self.makeBoundListener(port: port)
    }

    /// Runs the accept loop forever on the calling thread. `onReceive` is invoked
    /// on this same thread for each received frame.
    static func runServer(
        listener: SocketFD,
        maxFrameBytes: Int,
        onReceive: @escaping (Data) -> Void,
    ) {
        while true {
            let clientFD = accept(listener, nil, nil)
            if clientFD == invalidSocketFD {
                Log.debug("accept() failed; continuing.")
                continue
            }
            self.handleConnection(clientFD, maxFrameBytes: maxFrameBytes, onReceive: onReceive)
            Sock.close(clientFD)
        }
    }

    /// Connects to the peer, sends one frame, and closes. Best-effort: logs and
    /// returns on any failure so a sleeping/offline peer never blocks syncing.
    static func sendFrame(to host: String, port: UInt16, payload: Data) {
        Sock.prepare()

        guard let fd = connectTo(host: host, port: port) else {
            Log.warn("Could not reach peer at \(host):\(port); update not delivered.")
            return
        }
        defer { Sock.close(fd) }

        var frame = [UInt8]()
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(contentsOf: payload)

        if self.sendAll(fd, frame) {
            Log.info("Sent \(payload.count)-byte frame to \(host):\(port).")
        } else {
            Log.warn("Failed while sending to \(host):\(port).")
        }
    }

    // MARK: - Connection handling

    private static func handleConnection(
        _ fd: SocketFD,
        maxFrameBytes: Int,
        onReceive: (Data) -> Void,
    ) {
        guard let header = recvExactly(fd, count: 4) else { return }
        let length =
            (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        guard length > 0, length <= maxFrameBytes else {
            Log.warn("Rejecting frame with implausible length \(length).")
            return
        }
        guard let body = recvExactly(fd, count: length) else {
            Log.debug("Connection closed before full frame arrived.")
            return
        }
        onReceive(Data(body))
    }

    // MARK: - Socket setup

    private static func makeBoundListener(port: UInt16) -> SocketFD? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sock.stream
        hints.ai_flags = AI_PASSIVE

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(nil, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd != invalidSocketFD else { return nil }

        #if os(Windows)
            guard Sock.enableBoolOption(fd, Sock.exclusiveAddrUse) else {
                Sock.close(fd)
                return nil
            }
        #else
            guard Sock.enableBoolOption(fd, SO_REUSEADDR) else {
                Sock.close(fd)
                return nil
            }
        #endif

        let bindResult = bind(fd, info.pointee.ai_addr, Sock.addrLen(info.pointee.ai_addrlen))
        guard bindResult == 0 else {
            Sock.close(fd)
            return nil
        }
        guard listen(fd, 8) == 0 else {
            Sock.close(fd)
            return nil
        }
        return fd
    }

    private static func connectTo(host: String, port: UInt16) -> SocketFD? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sock.stream

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var candidate: UnsafeMutablePointer<addrinfo>? = info
        while let current = candidate {
            let address = current.pointee
            let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if fd != invalidSocketFD {
                Sock.setSendTimeout(fd, seconds: 3)
                if connect(fd, address.ai_addr, Sock.addrLen(address.ai_addrlen)) == 0 {
                    return fd
                }
                Sock.close(fd)
            }
            candidate = address.ai_next
        }
        return nil
    }

    // MARK: - Byte-accurate send/recv

    private static func sendAll(_ fd: SocketFD, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        return bytes.withUnsafeBytes { raw -> Bool in
            let base = raw.baseAddress!
            while sent < bytes.count {
                let remaining = bytes.count - sent
                #if os(Windows)
                    let n = send(fd, base.advanced(by: sent).assumingMemoryBound(to: CChar.self),
                                 Int32(remaining), 0)
                #else
                    let n = send(fd, base.advanced(by: sent), remaining, 0)
                #endif
                if n <= 0 { return false }
                sent += Int(n)
            }
            return true
        }
    }

    private static func recvExactly(_ fd: SocketFD, count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            let base = raw.baseAddress!
            while received < count {
                let remaining = count - received
                #if os(Windows)
                    let n = recv(fd, base.advanced(by: received).assumingMemoryBound(to: CChar.self),
                                 Int32(remaining), 0)
                #else
                    let n = recv(fd, base.advanced(by: received), remaining, 0)
                #endif
                if n <= 0 { return false }
                received += Int(n)
            }
            return true
        }
        return ok ? buffer : nil
    }
}
