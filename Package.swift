// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapRegions",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SnapRegions",
            path: "Sources/SnapRegions",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
