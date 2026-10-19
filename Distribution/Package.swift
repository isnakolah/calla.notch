// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallaNotchDistribution",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "calla-notch", targets: ["CallaNotchSetup"]),
        .executable(name: "calla-gateway", targets: ["CallaGateway"]),
        .library(name: "CallaNotchSetupUI", targets: ["CallaNotchSetupUI"]),
        .library(name: "DistributionCore", targets: ["DistributionCore"]),
    ],
    dependencies: [.package(path: "../CallaContracts")],
    targets: [
        .target(name: "DistributionCore", dependencies: [.product(name: "CallaContracts", package: "CallaContracts")]),
        .executableTarget(name: "CallaNotchSetup", dependencies: ["DistributionCore"]),
        .executableTarget(name: "CallaGateway", dependencies: ["DistributionCore"]),
        .target(name: "CallaNotchSetupUI", dependencies: ["DistributionCore"], path: "Sources/CallaNotchSetupUI"),
        .testTarget(name: "DistributionCoreTests", dependencies: ["DistributionCore"]),
    ]
)
