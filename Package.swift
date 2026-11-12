// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PadPal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PadPal", path: "Sources/PadPal")
    ]
)
