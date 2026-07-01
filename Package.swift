// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeVitals",
    platforms: [
        .macOS(.v14)   // MenuBarExtra(.window) floor; this machine is macOS 26.
    ],
    products: [
        .executable(name: "ClaudeVitals", targets: ["ClaudeVitals"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeVitals",
            path: "Sources/ClaudeVitals"
        ),
        .testTarget(
            name: "ClaudeVitalsTests",
            dependencies: ["ClaudeVitals"],
            path: "Tests/ClaudeVitalsTests"
        )
    ]
)
