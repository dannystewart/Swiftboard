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

        var frame = [UInt8]()
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(contentsOf: payload)

        let connection = connectTo(host: host, port: port)
        guard let fd = connection.fd else {
            #if os(macOS)
                if connection.error == EHOSTUNREACH,
                   self.sendFrameWithSystemNetcat(to: host, port: port, frame: frame)
                {
                    Log.info("Sent \(payload.count)-byte frame to \(host):\(port) using the macOS system transport.")
                    return
                }
            #endif
            if let error = connection.error {
                Log.warn(
                    "Could not connect to peer \(host):\(port) (OS error \(error)); update not delivered.",
                )
            }
            return
        }
        defer { Sock.close(fd) }

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

    private static func connectTo(host: String, port: UInt16) -> (fd: SocketFD?, error: Int32?) {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Sock.stream

        var result: UnsafeMutablePointer<addrinfo>?
        let resolveResult = getaddrinfo(host, String(port), &hints, &result)
        guard resolveResult == 0, let info = result else {
            Log.warn(
                "Could not resolve peer \(host):\(port) (getaddrinfo error \(resolveResult)); update not delivered.",
            )
            return (nil, nil)
        }
        defer { freeaddrinfo(result) }

        var lastError: Int32?
        var candidate: UnsafeMutablePointer<addrinfo>? = info
        while let current = candidate {
            let address = current.pointee
            let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            if fd != invalidSocketFD {
                Sock.setSendTimeout(fd, seconds: 30)
                if connect(fd, address.ai_addr, Sock.addrLen(address.ai_addrlen)) == 0 {
                    return (fd, nil)
                }
                lastError = Sock.lastErrorCode()
                Sock.close(fd)
            } else {
                lastError = Sock.lastErrorCode()
            }
            candidate = address.ai_next
        }
        if lastError == nil {
            Log.warn("Could not connect to peer \(host):\(port); update not delivered.")
        }
        return (nil, lastError)
    }

    #if os(macOS)
        /// macOS 27 beta can deny third-party local-network sockets with
        /// EHOSTUNREACH while allowing the same connection through /usr/bin/nc.
        private static func sendFrameWithSystemNetcat(
            to host: String,
            port: UInt16,
            frame: [UInt8],
        ) -> Bool {
            let process = Process()
            let input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-w", "30", host, String(port)]
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(frame))
                try input.fileHandleForWriting.close()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                try? input.fileHandleForWriting.close()
                return false
            }
        }
    #endif

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
