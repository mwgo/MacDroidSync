// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDroidSync",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacDroidSyncCore"),
        .executableTarget(name: "MacDroidSync", dependencies: ["MacDroidSyncCore"]),
        // The Share extension binary is started by _NSExtensionMain instead of
        // main(), which is what the linker flag below installs. build.sh wraps it
        // into MacDroidSync.app/Contents/PlugIns/ShareExtension.appex.
        .executableTarget(
            name: "ShareExtension",
            dependencies: ["MacDroidSyncCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "MacDroidSyncCoreTests", dependencies: ["MacDroidSyncCore"]),
    ]
)
