// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmbientBacklight",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AmbientBacklight",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
