// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZhiYuCore",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "ZhiYuCore", targets: ["ZhiYuCore"]),
    ],
    targets: [
        .target(name: "ZhiYuCore"),
        .testTarget(name: "ZhiYuCoreTests", dependencies: ["ZhiYuCore"]),
    ]
)
