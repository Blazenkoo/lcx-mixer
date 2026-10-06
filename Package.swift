// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LCXMixer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "LCXMixer",
            path: "Sources/LCXMixer",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
