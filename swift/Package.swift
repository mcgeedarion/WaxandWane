// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmbientBacklight",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "AmbientBacklight",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate")
            ]
        ),
        .testTarget(
            name: "PolicyTests",
            path: "Tests"
        ),
    ]
)
