// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "HomePodKeychainExtractor",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .executable(
            name: "HomePodKeychainExtractor",
            targets: ["HomePodKeychainExtractor"]
        ),
        .library(
            name: "KeychainKit",
            targets: ["KeychainKit"]
        ),
    ],
    dependencies: [
        .package(path: "Vendored/FoundationKit"),
        .package(path: "Vendored/LoggerKit"),
        .package(path: "Vendored/AuthenticationKit"),
        .package(path: "Vendored/CodeSignKit"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "KeychainKit",
            dependencies: [
                "FoundationKit",
                "LoggerKit",
            ],
            path: "Sources/KeychainKit",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "HomePodKeychainExtractor",
            dependencies: [
                "KeychainKit",
                "FoundationKit",
                "LoggerKit",
                "AuthenticationKit",
                "CodeSignKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/HomePodKeychainExtractor",
            exclude: [
                "HomePodKeychainExtractor.entitlements",
                "Info.plist",
            ]
        ),
        .testTarget(
            name: "LoggerKitTests",
            dependencies: ["LoggerKit"],
            path: "Vendored/LoggerKit/Tests/LoggerKitTests"
        ),
        .testTarget(
            name: "FoundationKitTests",
            dependencies: ["FoundationKit"],
            path: "Vendored/FoundationKit/Tests/FoundationKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
