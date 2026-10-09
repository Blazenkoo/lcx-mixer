// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LCXMixer",
    platforms: [.macOS("14.2")],
    targets: [
        // Everything the app does. A library so the tests can import it.
        .target(
            name: "LCXMixerKit",
            path: "Sources/LCXMixerKit",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        // The app itself: only main.swift, which starts LCXMixerKit.
        .executableTarget(
            name: "LCXMixer",
            dependencies: ["LCXMixerKit"],
            path: "Sources/LCXMixer"
        ),
        .testTarget(
            name: "LCXMixerKitTests",
            dependencies: ["LCXMixerKit"],
            path: "Tests/LCXMixerKitTests"
        ),
    ]
)
