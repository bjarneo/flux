// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flux",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FluxProto", targets: ["FluxProto"]),
        .library(name: "FluxNet", targets: ["FluxNet"]),
        .library(name: "FluxCore", targets: ["FluxCore"]),
        .library(name: "FluxFeatures", targets: ["FluxFeatures"]),
        .library(name: "FluxApprove", targets: ["FluxApprove"]),
        .library(name: "FluxCamera", targets: ["FluxCamera"]),
        .library(name: "FluxStream", targets: ["FluxStream"]),
        .library(name: "FluxUI", targets: ["FluxUI"]),
    ],
    dependencies: [
        // D1 browse: SSH client + SFTP over taken browse tunnels
        // (Citadel wraps NIOSSH; MIT — license choice stays with the
        // source owner). Exact pins: reproducible device builds.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
    ],
    targets: [
        .target(name: "FluxProto"),
        .target(name: "FluxNet", dependencies: ["FluxProto"]),
        .target(name: "FluxCore", dependencies: ["FluxProto", "FluxNet", "FluxApprove", .product(name: "Citadel", package: "Citadel"), .product(name: "NIO", package: "swift-nio")]),
        .target(name: "FluxFeatures", dependencies: ["FluxProto", "FluxCore", "FluxApprove"]),
        .target(name: "FluxApprove", dependencies: ["FluxProto"]),
        .target(name: "FluxCamera", dependencies: ["FluxProto"]),
        .target(name: "FluxStream", dependencies: ["FluxProto", "FluxCamera"]),
        .target(name: "FluxUI", dependencies: ["FluxProto", "FluxCore", "FluxApprove", "FluxCamera", "FluxStream"]),
        .executableTarget(name: "FluxTestPeer", dependencies: ["FluxProto", "FluxNet", "FluxCore", "FluxCamera", "FluxStream", "FluxApprove"]),
        .testTarget(name: "FluxProtoTests", dependencies: ["FluxProto"]),
        .testTarget(name: "FluxNetTests", dependencies: ["FluxNet", "FluxProto", "FluxCore"]),
        .testTarget(name: "FluxCoreTests", dependencies: ["FluxCore", "FluxProto", "FluxApprove"]),
        .testTarget(name: "FluxFeaturesTests", dependencies: ["FluxFeatures", "FluxProto", "FluxApprove"]),
        .testTarget(name: "FluxApproveTests", dependencies: ["FluxApprove", "FluxProto"]),
        .testTarget(name: "FluxCameraTests", dependencies: ["FluxCamera", "FluxProto"]),
        .testTarget(name: "FluxStreamTests", dependencies: ["FluxStream", "FluxProto", "FluxCamera"]),
        .testTarget(name: "FluxUITests", dependencies: ["FluxUI", "FluxProto", "FluxStream"]),
    ],
    swiftLanguageModes: [.v6]
)
