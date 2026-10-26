// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Repose",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Repose",
            path: "Sources/Repose",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
