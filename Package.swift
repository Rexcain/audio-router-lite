// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRouterLite",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AudioRouterLite", targets: ["AudioRouterLite"]),
        .executable(name: "ardiag", targets: ["ardiag"]),
    ],
    targets: [
        // Real-time audio core in C: ring buffers, resampler, drift control, mixing, IO callbacks.
        .target(
            name: "CRouterCore",
            cSettings: [.unsafeFlags(["-O2"])],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Device discovery, engine orchestration, models, persistence.
        .target(
            name: "AudioRouterKit",
            dependencies: ["CRouterCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // SwiftUI application.
        .executableTarget(
            name: "AudioRouterLite",
            dependencies: ["AudioRouterKit"]
        ),
        // Internal diagnostic CLI (device list, end-to-end loopback measurement).
        .executableTarget(
            name: "ardiag",
            dependencies: ["AudioRouterKit"]
        ),
        // Automated DSP / engine tests (self-contained runner; see Sources/RouterTests/main.swift).
        .executableTarget(
            name: "RouterTests",
            dependencies: ["CRouterCore", "AudioRouterKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
