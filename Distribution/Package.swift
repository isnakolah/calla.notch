// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoringNotchDistribution",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "boring-notch", targets: ["BoringNotchSetup"]),
        .executable(name: "calla-gateway", targets: ["CallaGateway"]),
        .library(name: "BoringNotchSetupUI", targets: ["BoringNotchSetupUI"]),
        .library(name: "DistributionCore", targets: ["DistributionCore"]),
    ],
    targets: [
        .target(name: "DistributionCore"),
        .executableTarget(name: "BoringNotchSetup", dependencies: ["DistributionCore"]),
        .executableTarget(name: "CallaGateway", dependencies: ["DistributionCore"]),
        .target(name: "BoringNotchSetupUI", dependencies: ["DistributionCore"], path: "Sources/BoringNotchSetupUI"),
        .testTarget(name: "DistributionCoreTests", dependencies: ["DistributionCore"]),
    ]
)
