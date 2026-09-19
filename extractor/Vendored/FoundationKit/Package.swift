// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "FoundationKit",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "FoundationKit",
            targets: ["FoundationKit"]
        ),
        .library(
            name: "FoundationKitMac",
            targets: ["FoundationKitMac"]
        ),
    ],
    targets: [
        .target(
            name: "FoundationKit",
            path: "Sources/FoundationKit"
        ),
        .target(
            name: "FoundationKitMac",
            path: "Sources/FoundationKitMac"
        ),
        .testTarget(
            name: "FoundationKitTests",
            dependencies: ["FoundationKit"],
            path: "Tests/FoundationKitTests"
        ),
    ]
)
