// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pocketbase",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "pocketbase",
            targets: ["pocketbase"]
        ),
    ],
    targets: [
        .target(
            name: "pocketbase"
        ),
        .testTarget(
            name: "pocketbaseTests",
            dependencies: ["pocketbase"]
        ),
    ]
)
