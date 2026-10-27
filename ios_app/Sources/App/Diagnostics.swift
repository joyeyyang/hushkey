import Foundation
import SwiftUI
import UIKit
import os

/// The boot-time facts, written to the system log and (on request) shown on screen.
///
/// The app once launched to a white screen with no crash and no log output at
/// all, which left nothing to read. These lines separate the three causes that
/// look identical from the outside: no scene connected (nothing renders), an
/// App Group the system never granted (models and the handoff are unreachable),
/// and a recogniser that cannot see its models.
enum Diagnostics {
    static let log = Logger(subsystem: "com.example.offlinevoiceassistant.ios", category: "boot")

    /// Launch argument that shows the report instead of the app. Passed to
    /// `simctl launch` as `-OVC_IOS_SMOKE`; it never affects a normal launch.
    static let smokeFlag = "-OVC_IOS_SMOKE"

    static var isSmokeRun: Bool {
        ProcessInfo.processInfo.arguments.contains(smokeFlag)
    }

    /// `-OVC_RECORD`: start a dictation from the microphone at launch, the same
    /// path the keyboard's `ovc://record` takes. The simulator has no audio input,
    /// which is exactly why it is worth exercising: the failure has to be a
    /// sentence on screen, not a crash in the audio engine.
    static var startsRecording: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_RECORD")
    }

    /// `-OVC_AUDIO_FILE <path>`: run the pipeline over a file instead of the
    /// microphone. The simulator has no usable microphone, and this doubles as
    /// the regression entry point -- a known sentence in, the same text out.
    static var injectedAudio: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-OVC_AUDIO_FILE"),
              args.index(after: index) < args.endIndex
        else { return nil }
        return args[args.index(after: index)]
    }

    struct Line: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let ok: Bool
    }

    static func report() -> [Line] {
        var lines: [Line] = []

        let bundle = Bundle.main.bundleIdentifier ?? "(nil)"
        lines.append(Line(label: "bundle", value: bundle, ok: !bundle.isEmpty))

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append(Line(
            label: "system",
            value: "app \(version) · iOS \(os.majorVersion).\(os.minorVersion) · \(UIDevice.current.model)",
            ok: true
        ))

        // Present only if the Info.plist carries the scene dictionary.
        let hasScene = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil
        lines.append(Line(label: "scene", value: hasScene ? "manifest present" : "MISSING", ok: hasScene))

        let container = SharedStore.container
        let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroup
        ) != nil
        lines.append(Line(
            label: "app group",
            value: shared ? container.path : "unavailable (fallback: \(container.lastPathComponent))",
            ok: shared
        ))

        lines.append(Line(
            label: "models",
            value: "\(SharedStore.hasModels ? "found" : "missing") · \(SharedStore.modelsRoot.path)",
            ok: SharedStore.hasModels
        ))

        // Which LLM will actually run. A downgrade is a decision made on the
        // user's behalf, so every launch states it rather than leaving the reason
        // buried in the launch that recorded it.
        let llm = LLMPolicy.recorded
        // Requested and installed are printed separately on purpose: with only a
        // small model on the device the old single line read "preferred ·
        // qwen2.5-0.5b…", which claims a preference that is not installed.
        lines.append(Line(
            label: "llm",
            value: llm.map { "wanted \($0.from) · using \($0.to) · \($0.reason)" }
                ?? "wanted \(LLMPolicy.preferredName) · installed \(LLMPolicy.preferredInstalled?.name ?? "none")",
            ok: SharedStore.hasLLM
        ))

        return lines
    }

    /// Writes every line to the unified log. Called once at launch, before any UI
    /// is built, so a launch that never reaches a view is still readable.
    static func emit() {
        log.notice("boot \(Bundle.main.bundleIdentifier ?? "(nil)", privacy: .public)")
        for line in report() {
            log.notice("\(line.label, privacy: .public)=\(line.value, privacy: .public) ok=\(line.ok, privacy: .public)")
        }
    }
}

/// The smoke screen: the report as text, so a screenshot proves the app reached
/// a live scene. Not part of the product; only reachable with the launch flag.
struct SmokeView: View {
    private let lines = Diagnostics.report()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("BOOT REPORT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(line.ok ? .green : .red)
                        Text(line.value)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }
}
