// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortifoBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that isn't AppKit: Yahoo's feeds and the quotes built from them.
        .target(name: "PortifoBarCore"),
        // The menu bar app itself.
        .executableTarget(name: "PortifoBar", dependencies: ["PortifoBarCore"]),
        .testTarget(name: "PortifoBarCoreTests", dependencies: ["PortifoBarCore"]),
    ]
)
