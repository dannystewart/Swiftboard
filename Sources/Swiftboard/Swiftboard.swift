import Foundation
import PolyLog

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

        SwiftboardLogging.start(verbose: config.verbose)
        logger.info("Swiftboard process starting (PID \(ProcessInfo.processInfo.processIdentifier)).")

        do {
            _ = try SwiftboardService(config: config)
        } catch {
            logger.error("\(error) Exiting for supervisor restart.")
            SwiftboardLogging.shutdownAndWait()
            exit(1)
        }

        while true {
            Thread.sleep(forTimeInterval: 3600)
        }
    }
}
