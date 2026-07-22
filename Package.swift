// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
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
