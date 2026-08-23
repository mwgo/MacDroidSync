// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDroidSync",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacDroidSyncCore"),
        .executableTarget(name: "MacDroidSync", dependencies: ["MacDroidSyncCore"]),
        .testTarget(name: "MacDroidSyncCoreTests", dependencies: ["MacDroidSyncCore"]),
    ]
)
