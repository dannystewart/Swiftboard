// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let macOSInfoPlist = URL(fileURLWithPath: packageDirectory)
    .appendingPathComponent("Sources/Swiftboard/Info.plist").path

let package = Package(
    name: "Swiftboard",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "swiftboard", targets: ["Swiftboard"]),
    ],
    targets: [
        // C shim over stb_image / stb_image_write, used only on Windows to
        // convert between the clipboard's DIB and the PNG we send on the wire.
        // macOS uses NSBitmapImageRep instead, so it never depends on this.
        .target(name: "CSTBImage"),
        .executableTarget(
            name: "Swiftboard",
            dependencies: [
                .target(name: "CSTBImage", condition: .when(platforms: [.windows])),
            ],
            exclude: ["Info.plist"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                // Swift 6.3.2 for Windows asserts in ClosureSpecializer when
                // optimizing this target. Keep release builds optimized while
                // disabling only the crashing pass.
                .unsafeFlags(
                    ["-Xllvm", "-sil-disable-pass=ClosureSpecializer"],
                    .when(platforms: [.windows], configuration: .release),
                ),
            ],
            linkerSettings: [
                // Give the standalone macOS CLI a stable privacy identity without
                // wrapping it in an application bundle.
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", macOSInfoPlist,
                    ],
                    .when(platforms: [.macOS]),
                ),
                // Link as a GUI-subsystem app on Windows so no console window is
                // ever created (headless startup). /ENTRY:mainCRTStartup keeps the
                // normal `main` entry point that @main provides, rather than the
                // WinMain the WINDOWS subsystem would otherwise expect.
                .unsafeFlags(
                    ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                    .when(platforms: [.windows])
                ),
            ],
        ),
        .testTarget(
            name: "SwiftboardTests",
            dependencies: ["Swiftboard"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ],
)
