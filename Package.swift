// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrightBoi",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "BrightBoi",
            path: "Sources/BrightBoi"
        )
    ]
)
