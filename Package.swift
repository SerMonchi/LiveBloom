// swift-tools-version:5.9
// For editing in Xcode or VS Code. The finished app is built by ./build.sh (see README).
import PackageDescription

let package = Package(
    name: "LiveBloom",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "LiveBloom", path: "Sources/LiveBloom")
    ]
)
