// swift-tools-version:5.9
// phase0/swift-poc/Package.swift
import PackageDescription

let package = Package(
    name: "MiragePOC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "MiragePOC",
            dependencies: [.product(name: "GRPC", package: "grpc-swift")],
            path: "Sources/MiragePOC"
        ),
    ]
)
