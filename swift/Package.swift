// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WaxAndWane",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wax-and-wane", targets: ["WaxAndWane"]),
        .library(name: "WaxAndWaneCore", targets: ["WaxAndWaneCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "WaxAndWaneCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WaxAndWaneCore",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("Accelerate", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "WaxAndWane",
            dependencies: ["WaxAndWaneCore"],
            path: "Sources/WaxAndWane"
        ),
        .testTarget(
            name: "PolicyTests",
            dependencies: ["WaxAndWaneCore"],
            path: "Tests"
        ),
    ]
)
