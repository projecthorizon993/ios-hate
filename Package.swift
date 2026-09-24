// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumaFrame",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LumaFrame", targets: ["LumaFrame"])
    ],
    targets: [
        .target(
            name: "LumaFrame",
            path: "App/Sources"
        ),
        .testTarget(
            name: "LumaFrameTests",
            dependencies: ["LumaFrame"],
            path: "App/Tests"
        )
    ]
)
