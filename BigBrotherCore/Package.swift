// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BigBrotherCore",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "BigBrotherCore",
            targets: ["BigBrotherCore"]
        ),
    ],
    targets: [
        .target(
            name: "BigBrotherCore",
            path: "Sources/BigBrotherCore"
        ),
        .testTarget(
            name: "BigBrotherCoreTests",
            dependencies: ["BigBrotherCore"],
            path: "Tests/BigBrotherCoreTests"
        ),
    ]
)
