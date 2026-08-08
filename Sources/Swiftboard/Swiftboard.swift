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

        // Do this first: the headless Windows build has no console, so the file
        // is the only place logs can land.
        if let logPath = Log.startFileLogging() {
            Log.info("Logging to \(logPath).")
        }
        Log.info("Swiftboard process starting (PID \(ProcessInfo.processInfo.processIdentifier)).")

        do {
            _ = try SwiftboardService(config: config)
        } catch {
            Log.error("\(error) Exiting for supervisor restart.")
            exit(1)
        }

        while true {
            Thread.sleep(forTimeInterval: 3600)
        }
    }
}
