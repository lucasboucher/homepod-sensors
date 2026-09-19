// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "CodeSignKit",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "CodeSignKit",
            targets: ["CodeSignKit"]
        ),
    ],
    dependencies: [
        .package(path: "../FoundationKit"),
        .package(path: "../LoggerKit"),
    ],
    targets: [
        .target(
            name: "CodeSignKit",
            dependencies: [
                "FoundationKit",
                "LoggerKit",
            ],
            path: "Sources/CodeSignKit"
        ),
        .testTarget(
            name: "CodeSignKitTests",
            dependencies: ["CodeSignKit"],
            path: "Tests/CodeSignKitTests"
        ),
    ]
)
