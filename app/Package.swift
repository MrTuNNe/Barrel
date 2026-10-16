// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Barrel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Barrel", path: "Sources/Barrel")
    ]
)
