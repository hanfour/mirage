// swift-tools-version:5.9
import PackageDescription

let strict = [SwiftSetting.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
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
            dependencies: ["MirageCore"]
        ),
    ]
)
