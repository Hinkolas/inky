// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InkyCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "InkyCore", targets: ["InkyCore"]),
    ],
    targets: [
        .target(name: "InkyCore"),
        .testTarget(name: "InkyCoreTests", dependencies: ["InkyCore"]),
    ]
)
