// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMix",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMix", targets: ["AgentMixApp"]),
        .executable(name: "AgentMixHelper", targets: ["AgentMixHelper"]),
        .library(name: "AgentMixCore", targets: ["AgentMixCore"]),
    ],
    targets: [
        .target(name: "AgentMixCore"),
        .executableTarget(name: "AgentMixApp", dependencies: ["AgentMixCore"]),
        .executableTarget(name: "AgentMixHelper", dependencies: ["AgentMixCore"]),
        .testTarget(name: "AgentMixCoreTests", dependencies: ["AgentMixCore"]),
        .testTarget(name: "AgentMixHelperTests", dependencies: ["AgentMixHelper", "AgentMixCore"]),
    ],
    swiftLanguageModes: [.v5]
)
