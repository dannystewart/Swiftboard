import Foundation

#if os(Windows)
    import WinSDK

    typealias SocketFD = SOCKET
    /// INVALID_SOCKET is a cast-style C macro Swift's importer doesn't surface, so
    /// compute the equivalent (all bits set) directly. SOCKET is an unsigned type.
    let invalidSocketFD: SOCKET = ~0

    /// Initialized once, lazily and thread-safely, before any socket use.
    private let winsockReady: Bool = {
        var data = WSADATA()
        return WSAStartup(WORD(0x0202), &data) == 0
    }()
#else
    import Darwin

    typealias SocketFD = Int32
    let invalidSocketFD: Int32 = -1
#endif

// MARK: - Sock

/// Cross-platform socket primitives shared by the TCP data channel (Transport)
/// and the UDP discovery beacon (Discovery). The POSIX/WinSock differences all
/// live here so the callers stay readable.
enum Sock {
    #if os(Windows)
        static let stream: Int32 = .init(SOCK_STREAM)
        static let dgram: Int32 = .init(SOCK_DGRAM)
        // SO_EXCLUSIVEADDRUSE is defined as a C expression that Swift cannot import.
        static let exclusiveAddrUse: Int32 = ~SO_REUSEADDR
    #else
        static let stream = SOCK_STREAM
        static let dgram = SOCK_DGRAM
    #endif

    static func prepare() {
        #if os(Windows)
            _ = winsockReady
        #endif
    }

    // bind/connect want the address length as `int` on Windows (WinSock) but as
    // socklen_t on Darwin; socklen_t may not exist in the Windows overlay.
    #if os(Windows)
        static func addrLen(_ len: some BinaryInteger) -> Int32 { Int32(len) }
    #else
        static func addrLen(_ len: some BinaryInteger) -> socklen_t { socklen_t(len) }
    #endif

    static func close(_ fd: SocketFD) {
        #if os(Windows)
            closesocket(fd)
        #else
            Darwin.close(fd)
        #endif
    }

    /// Sets a boolean SO_* option (e.g. SO_REUSEADDR, SO_BROADCAST) to 1.
    static func enableBoolOption(_ fd: SocketFD, _ option: Int32) -> Bool {
        var one: Int32 = 1
        #if os(Windows)
            return withUnsafePointer(to: &one) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) { cptr in
                    setsockopt(fd, SOL_SOCKET, option, cptr, Int32(MemoryLayout<Int32>.size)) == 0
                }
            }
        #else
            return setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        #endif
    }

    static func setSendTimeout(_ fd: SocketFD, seconds: Int) {
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
