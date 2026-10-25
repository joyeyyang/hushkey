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
            // The app now consumes the packaged voice-input pipeline: the cleanup
            // chain (keyword narrowing, spoken-edit hint, sanity guard, fallback)
            // has one implementation, in VoiceInputKit, and the command-line tool
            // uses the same one.
            dependencies: ["COfflineVoiceCore", "VoiceInputKit"],
            path: "Sources/OfflineVoiceAssistant",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/../core_engine/target/release",
                    "-loffline_voice_core",
                ]),
            ]
        ),
        .target(
            name: "VoiceInputKit",
            dependencies: ["COfflineVoiceCore"],
            path: "Sources/VoiceInputKit",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/../core_engine/target/release",
                    "-loffline_voice_core",
                ]),
            ]
        ),
        .executableTarget(
            name: "voiceinput",
            dependencies: ["VoiceInputKit", "COfflineVoiceCore"],
            path: "Sources/voiceinput",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/../core_engine/target/release",
                    "-loffline_voice_core",
                ]),
            ]
        ),
    ]
)
