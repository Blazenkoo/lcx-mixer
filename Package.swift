// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MediaMixer",
    platforms: [.macOS("14.2")],
    targets: [
        // Everything the app does. A library so the tests can import it.
        .target(
            name: "MediaMixerKit",
            path: "Sources/MediaMixerKit",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        // The app itself: only main.swift, which starts MediaMixerKit.
        .executableTarget(
            name: "MediaMixer",
            dependencies: ["MediaMixerKit"],
            path: "Sources/MediaMixer"
        ),
        .testTarget(
            name: "MediaMixerKitTests",
            dependencies: ["MediaMixerKit"],
            path: "Tests/MediaMixerKitTests"
        ),
    ]
)
