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
        // P1-e：SPSC 無鎖環形緩衝需要 atomic 讀寫索引。1.3.1 已存在於 Package.resolved
        // （grpc-swift 的傳遞依賴），此處只是宣告成可 import 的 product，不引入新的網路依賴。
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strict
        ),
        .target(
            name: "MirageShell",
            dependencies: ["MirageCore"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MirageApp",
            dependencies: ["MirageShell"],
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
