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
        // 手機遙控：沿用已解析的傳遞依賴版本，供 RemoteServer 使用。
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            // 內建範例 profile。`.copy` 而非 `.process`：這是 JSON，不需要任何編譯期
            // 處理，`.copy` 保持 profiles/ 這層目錄結構原樣（查表時要用 subdirectory）。
            //
            // 這個宣告在 2026-07-29 之前**不存在**，所以 `app/Resources/profiles/` 裡那個
            // 檔案對建置系統而言不存在——它永遠到不了使用者的 Application Support 目錄。
            // 那就是債務 D4 的本體。
            resources: [
                .copy("Resources/profiles"),
                .copy("Resources/remote"),
                .copy("Resources/instances.conf"),
                .copy("Resources/sdk-spec.json"),
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
        .target(
            name: "MiragePull",
            dependencies: ["MirageCore"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "mirage-pull",
            dependencies: ["MiragePull"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: [
                "MirageCore",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MirageShellTests",
            dependencies: [
                "MirageShell",
                "MirageCore",   // 測試會直接用 ViewportFit / AudioRingBuffer 等公開型別
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MiragePullTests",
            dependencies: [
                "MiragePull",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: strict
        ),
    ]
)
