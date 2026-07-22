import Foundation

struct Config: Sendable {
    var peerHost: String
    var port: UInt16 = 8765
    var maxSizeMB: Int = 10
    var pollIntervalMS: Int = 250
    var syncImages: Bool = true
    var verbose: Bool = false

    var maxSizeBytes: Int { maxSizeMB * 1024 * 1024 }

    static let usage = """
    Swiftboard - sync the clipboard between two machines on the same LAN.

    USAGE:
      swiftboard --peer <host> [options]

    OPTIONS:
      --peer <host>        IP or hostname of the other machine (required)
      --port <n>           TCP port to listen on and connect to (default: 8765)
      --max-size <mb>      Maximum clipboard payload in MB (default: 10)
      --interval <ms>      Clipboard poll interval in milliseconds (default: 250)
      --no-images          Sync text only; ignore images
      --verbose            Enable debug logging
      -h, --help           Show this help

    Run the same command on both machines, each pointing --peer at the other.
    """
}

enum ArgError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(text): text
        }
    }
}

enum ArgParser {
    // Returns nil when help was requested (caller should print usage and exit 0).
    static func parse(_ arguments: [String]) throws -> Config? {
        var peerHost: String?
        var config = Config(peerHost: "")

        var index = 0
        let args = Array(arguments.dropFirst()) // drop executable path
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-h", "--help":
                return nil
            case "--peer":
                peerHost = try value(after: arg, args: args, index: &index)
            case "--port":
                let raw = try value(after: arg, args: args, index: &index)
                guard let port = UInt16(raw) else {
                    throw ArgError.message("--port must be a number between 0 and 65535")
                }
                config.port = port
            case "--max-size":
                let raw = try value(after: arg, args: args, index: &index)
                guard let mb = Int(raw), mb > 0 else {
                    throw ArgError.message("--max-size must be a positive integer")
                }
                config.maxSizeMB = mb
            case "--interval":
                let raw = try value(after: arg, args: args, index: &index)
                guard let ms = Int(raw), ms >= 20 else {
                    throw ArgError.message("--interval must be at least 20 (ms)")
                }
                config.pollIntervalMS = ms
            case "--no-images":
                config.syncImages = false
            case "--verbose":
                config.verbose = true
            default:
                throw ArgError.message("unknown argument: \(arg)")
            }
            index += 1
        }

        guard let peerHost, !peerHost.isEmpty else {
            throw ArgError.message("--peer is required (the other machine's IP or hostname)")
        }
        config.peerHost = peerHost
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
