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
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.0.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "Voice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Voice",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(name: "VoiceTests", dependencies: ["Voice"])
    ]
)
