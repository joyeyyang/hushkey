// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OfflineVoiceAssistant",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "COfflineVoiceCore",
            path: "Sources/COfflineVoiceCore"
        ),
        .executableTarget(
            name: "OfflineVoiceAssistant",
            dependencies: ["COfflineVoiceCore"],
            path: "Sources/OfflineVoiceAssistant",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/../core_engine/target/release",
                    "-loffline_voice_core",
                ]),
            ]
        ),
    ]
)
