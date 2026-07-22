import Foundation

#if os(Windows)
import WinSDK
typealias SocketFD = SOCKET
private let invalidSocketFD = INVALID_SOCKET

// Initialized once, lazily and thread-safely, before any socket use.
private let winsockReady: Bool = {
    var data = WSADATA()
    return WSAStartup(WORD(0x0202), &data) == 0
}()
#else
import Darwin
typealias SocketFD = Int32
private let invalidSocketFD: Int32 = -1
#endif

// Length-prefixed framing: a 4-byte big-endian payload length followed by the
// JSON bytes. One frame per clipboard update; the sender opens a fresh
// connection per update and closes it, which keeps the protocol stateless.
enum Transport {
    // Runs the accept loop forever on the calling thread. `onReceive` is invoked
    // on this same thread for each received frame.
    static func runServer(
        port: UInt16,
        maxFrameBytes: Int,
        onReceive: @escaping (Data) -> Void
    ) {
        prepare()

        guard let listenFD = makeBoundListener(port: port) else {
            Log.error("Failed to bind listener on port \(port). Is another instance running?")
            return
        }
        Log.info("Listening for peer clipboard updates on port \(port).")

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD == invalidSocketFD {
                Log.debug("accept() failed; continuing.")
                continue
            }
            handleConnection(clientFD, maxFrameBytes: maxFrameBytes, onReceive: onReceive)
            closeSocket(clientFD)
        }
    }

    // Connects to the peer, sends one frame, and closes. Best-effort: logs and
    // returns on any failure so a sleeping/offline peer never blocks syncing.
    static func sendFrame(to host: String, port: UInt16, payload: Data) {
        prepare()

        guard let fd = connectTo(host: host, port: port) else {
            Log.warn("Could not reach peer at \(host):\(port); update not delivered.")
            return
        }
        defer { closeSocket(fd) }

        var frame = [UInt8]()
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(contentsOf: payload)

        if sendAll(fd, frame) {
            Log.debug("Sent \(payload.count)-byte frame to \(host):\(port).")
        } else {
            Log.warn("Failed while sending to \(host):\(port).")
        }
    }

    // MARK: - Connection handling

    private static func handleConnection(
        _ fd: SocketFD,
        maxFrameBytes: Int,
        onReceive: (Data) -> Void
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

    private static func prepare() {
        #if os(Windows)
        _ = winsockReady
        #endif
    }

    private static func makeBoundListener(port: UInt16) -> SocketFD? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = sockStream
        hints.ai_flags = AI_PASSIVE

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(nil, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd != invalidSocketFD else { return nil }

        setReuseAddr(fd)

        let bindResult = bind(fd, info.pointee.ai_addr, addrLen(info.pointee.ai_addrlen))
        guard bindResult == 0 else {
            closeSocket(fd)
            return nil
        }
        guard listen(fd, 8) == 0 else {
            closeSocket(fd)
            return nil
        }
        return fd
    }

    private static func connectTo(host: String, port: UInt16) -> SocketFD? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = sockStream

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd != invalidSocketFD else { return nil }

        setSendTimeout(fd, seconds: 3)
        guard connect(fd, info.pointee.ai_addr, addrLen(info.pointee.ai_addrlen)) == 0 else {
            closeSocket(fd)
            return nil
        }
        return fd
    }

    // MARK: - Byte-accurate send/recv

    private static func sendAll(_ fd: SocketFD, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        let ok = bytes.withUnsafeBytes { raw -> Bool in
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
        return ok
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

    // MARK: - Platform shims

    #if os(Windows)
    private static let sockStream = Int32(SOCK_STREAM)
    #else
    private static let sockStream = SOCK_STREAM
    #endif

    private static func addrLen(_ len: some BinaryInteger) -> socklen_t {
        socklen_t(len)
    }

    private static func closeSocket(_ fd: SocketFD) {
        #if os(Windows)
        closesocket(fd)
        #else
        close(fd)
        #endif
    }

    private static func setReuseAddr(_ fd: SocketFD) {
        var one: Int32 = 1
        #if os(Windows)
        withUnsafePointer(to: &one) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { cptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, cptr, Int32(MemoryLayout<Int32>.size))
            }
        }
        #else
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func setSendTimeout(_ fd: SocketFD, seconds: Int) {
        #if os(Windows)
        var ms = DWORD(seconds * 1000)
        withUnsafePointer(to: &ms) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<DWORD>.size) { cptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, cptr, Int32(MemoryLayout<DWORD>.size))
            }
        }
        #else
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
    }
}
