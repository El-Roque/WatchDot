// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchDot",
    platforms: [.macOS(.v13), .watchOS(.v11)],
    products: [.library(name: "WatchDotCore", targets: ["WatchDotCore"])],
    targets: [
        .target(name: "WatchDotCore"),
        .testTarget(name: "WatchDotCoreTests", dependencies: ["WatchDotCore"])
    ]
)
