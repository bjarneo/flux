// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FluxKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FluxKit", targets: ["FluxKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
        // SSH and SFTP client for Browse files. 0.12.1 moves swift-nio-ssh to a
        // third-party fork, so stay on 0.12.0, which uses the maintainer's fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "FluxKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Citadel", package: "Citadel"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FluxKitTests",
            dependencies: ["FluxKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
