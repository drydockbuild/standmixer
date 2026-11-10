// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StandMixer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StandMixer", targets: ["StandMixerApp"]),
        .executable(name: "StandMixerHelper", targets: ["StandMixerHelper"]),
        .library(name: "StandMixerCore", targets: ["StandMixerCore"]),
    ],
    targets: [
        .target(name: "StandMixerCore"),
        .executableTarget(name: "StandMixerApp", dependencies: ["StandMixerCore"]),
        .executableTarget(name: "StandMixerHelper", dependencies: ["StandMixerCore"]),
        .testTarget(name: "StandMixerCoreTests", dependencies: ["StandMixerCore"]),
        .testTarget(name: "StandMixerHelperTests", dependencies: ["StandMixerHelper", "StandMixerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
