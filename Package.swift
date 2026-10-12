// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CapitalBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CapitalBar", path: "Sources/CapitalBar")
    ]
)
