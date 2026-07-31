// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-pocketbase-sdk",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(
            name: "swift-pocketbase-sdk",
            targets: ["swift-pocketbase-sdk"]
        ),
    ],
    targets: [
        .target(
            name: "swift-pocketbase-sdk"
        ),
        .testTarget(
            name: "swift-pocketbase-sdkTests",
            dependencies: ["swift-pocketbase-sdk"]
        ),
    ]
)
