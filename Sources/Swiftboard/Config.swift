import Foundation

// MARK: - Config

struct Config: Sendable {
    static let usage = """
    Swiftboard - sync the clipboard between two machines on the same LAN.

    USAGE:
      swiftboard [peer] [--port <n>] [--verbose]

    ARGUMENTS:
      [peer]        IP or hostname of the other machine. If omitted, Swiftboard
                    finds the peer automatically via UDP broadcast on the LAN.

    OPTIONS:
      --port <n>    TCP/UDP port to use (default: 8765)
      --verbose     Enable debug logging
      -h, --help    Show this help

    Run it on both machines. With no peer given, they discover each other.
    """

    // Set from the command line. A nil peer means discover it via UDP broadcast.
    var peerHost: String? = nil
    var port: UInt16 = 8765
    var verbose: Bool = false

    // Fixed defaults. Not exposed as flags on purpose; change them here if needed.
    var maxSizeMB: Int = 10
    var pollIntervalMS: Int = 250
    var syncImages: Bool = true

    var maxSizeBytes: Int { self.maxSizeMB * 1024 * 1024 }
}

// MARK: - ArgError

enum ArgError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(text): text
        }
    }
}

// MARK: - ArgParser

enum ArgParser {
    /// Returns nil when help was requested (caller should print usage and exit 0).
    static func parse(_ arguments: [String]) throws -> Config? {
        var peerHost: String?
        var port: UInt16 = 8765
        var verbose = false

        var index = 0
        let args = Array(arguments.dropFirst()) // drop executable path
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                return nil

            case "--port":
                let raw = try value(after: arg, args: args, index: &index)
                guard let parsed = UInt16(raw) else {
                    throw ArgError.message("--port must be a number between 0 and 65535")
                }
                port = parsed

            case "--verbose":
                verbose = true

            default:
                if arg.hasPrefix("-") {
                    throw ArgError.message("unknown argument: \(arg)")
                }
                guard peerHost == nil else {
                    throw ArgError.message("unexpected extra argument: \(arg)")
                }
                peerHost = arg
            }
            index += 1
        }

        var config = Config(peerHost: peerHost)
        config.port = port
        config.verbose = verbose
        return config
    }

    private static func value(after flag: String, args: [String], index: inout Int) throws -> String {
        guard index + 1 < args.count else {
            throw ArgError.message("\(flag) requires a value")
        }
        index += 1
        return args[index]
    }
}
