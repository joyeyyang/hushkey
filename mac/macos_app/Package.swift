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
                    "-L\(Context.packageDirectory)/../../rust/core_engine/target/release",
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
                    "-L\(Context.packageDirectory)/../../rust/core_engine/target/release",
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
                    "-L\(Context.packageDirectory)/../../rust/core_engine/target/release",
                    "-loffline_voice_core",
                ]),
            ]
        ),
        // The kit's pure text rules, exercised on their own. The insertion
        // search is the one that decides WHICH occurrence of a pasted text an
        // edit replaces, and the wrong occurrence replaces a sentence the user
        // did not mean -- a failure that is invisible until it has happened.
        .testTarget(
            name: "VoiceInputKitTests",
            dependencies: ["VoiceInputKit"],
            path: "Tests/VoiceInputKitTests"
        ),
    ]
)
