// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MPCConverter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MPCConverter",
            path: "Sources/MPCConverter",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
