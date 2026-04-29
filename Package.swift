// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mikkelsworkspace",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mikkelsworkspace",
            path: "Sources/mikkelsworkspace",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
