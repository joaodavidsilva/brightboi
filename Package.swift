// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrightBoi",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BrightBoi",
            path: "Sources/BrightBoi"
        )
    ]
)
