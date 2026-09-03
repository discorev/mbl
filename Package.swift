// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.12.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "Voice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Voice"
        )
    ]
)
