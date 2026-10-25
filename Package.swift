// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sentinel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SentinelCommon", path: "Sources/SentinelCommon"),
        .executableTarget(name: "SentinelHelper", dependencies: ["SentinelCommon"], path: "Sources/SentinelHelper"),
        .executableTarget(name: "Sentinel", dependencies: ["SentinelCommon"], path: "Sources/Sentinel"),
        .testTarget(name: "SentinelTests", dependencies: ["Sentinel", "SentinelCommon"], path: "Tests/SentinelTests"),
    ]
)
