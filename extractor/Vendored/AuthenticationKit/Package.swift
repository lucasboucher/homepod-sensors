// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "AuthenticationKit",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "AuthenticationKit",
            targets: ["AuthenticationKit"]
        ),
    ],
    targets: [
        .target(
            name: "AuthenticationKit",
            path: "Sources/AuthenticationKit"
        ),
    ]
)
