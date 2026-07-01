// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glance",
    platforms: [.macOS(.v14)], // NFR3: macOS 14 (Sonoma) floor — ScreenCaptureKit still-capture
    targets: [
        .executableTarget(
            name: "Glance",
            path: "Sources/Glance",
            swiftSettings: [
                // AppKit main-thread work is pervasive; keep concurrency checks sane for a UI app.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),          // RegisterEventHotKey (FR1)
                .linkedFramework("ScreenCaptureKit"), // SCScreenshotManager (FR6)
                .linkedFramework("ServiceManagement") // SMAppService launch-at-login (FR18)
            ]
        )
    ]
)
