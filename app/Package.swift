// swift-tools-version:6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            dependencies: [.product(name: "GRPC", package: "grpc-swift")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MirageApp",
            dependencies: ["MirageCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: [
                "MirageCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: strict
        ),
    ]
)
