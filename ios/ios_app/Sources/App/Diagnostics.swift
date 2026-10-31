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
        path(after: "-OVC_AUDIO_FILE")
    }

    /// `-OVC_AFTER_CLEAR <path>`, together with `-OVC_CLEAR`: dictate again in the
    /// same process, a few seconds after the clear. That is the sequence a user
    /// performs (清除, then the keyboard's microphone) and the only way to see
    /// whether the cancelled run left the recogniser session open -- a relaunch
    /// would hide it, because the session lives in this process.
    static var audioAfterClear: String? {
        path(after: "-OVC_AFTER_CLEAR")
    }

    /// `-OVC_DEVICE_BENCH`: measure the three M6 numbers on this device and write
    /// them to `Documents/bench.json`.
    ///
    /// The simulator cannot answer any of them -- its Metal backend is disabled
    /// and its memory is a desktop's -- so the only way to record "2B takes N
    /// seconds and M megabytes on this phone" is to ask a phone. Kept behind a
    /// flag so a normal launch never pays for it.
    static var runsDeviceBench: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_DEVICE_BENCH")
    }

    /// `-OVC_REFINE_TEXT <text>`: run one literal transcript through the cleanup
    /// pass and print the result.
    ///
    /// The microphone is the only thing this skips. A phone in a quiet room, a
    /// cable, and a sentence someone has to remember to say is a bad harness for
    /// "does the cleanup actually clean"; a fixed string in, the model's answer
    /// out, on the device's own silicon, is a good one. Written to
    /// `Documents/refine.json` as well as stdout.
    static var refineText: String? {
        path(after: "-OVC_REFINE_TEXT")
    }

    /// `-OVC_KB_EDIT_PROBE <instruction>`: the keyboard's 修改的提示詞 request,
    /// written from inside the app so the whole round trip can be run from a
    /// script.
    ///
    /// The keyboard cannot be tapped from the command line, and the part worth
    /// checking is not the tap -- it is the request crossing to the app, being
    /// acknowledged, and coming back with the core's answer. This posts the same
    /// request through `SharedStore`, which is the only line the keyboard uses,
    /// and writes the outcome to `Documents/keyboard-edit.json`.
    static var keyboardEditInstruction: String? {
        path(after: "-OVC_KB_EDIT_PROBE")
    }

    /// `-OVC_PAUSE_PROBE`: start a dictation and pause/resume it over the App
    /// Group, exactly as the keyboard's buttons do.
    ///
    /// The buttons themselves cannot be pressed from a script, and the part that
    /// can break is not the button -- it is the Darwin notification crossing to a
    /// backgrounded app, which is the whole reason the controls live on the
    /// keyboard at all. This posts the same two notifications on a timer and lets
    /// the log say whether the app heard them.
    static var probesPause: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_PAUSE_PROBE")
    }

    /// `-OVC_STOP_PROBE`: start a dictation, leave it alone for six seconds of
    /// silence, then post the same stop request the keyboard's button posts, and
    /// record the phase at each step.
    static var probesStop: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_STOP_PROBE")
    }

    /// `-OVC_STUCK_PROBE`: leave the recorder page on screen and record what the
    /// pipeline's phase does after a decode that never comes back.
    ///
    /// The user's report was "the microphone will not press", which is a phase that
    /// never ends rather than anything about the microphone. Paired with
    /// `-OVC_HANG_DECODE` and a spool planted in the App Group, the launch does the
    /// rest: `prepare()` → `recoverOrphan()` → `.transcribing`. Nothing about the
    /// state is synthetic.
    static var probesStuck: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_STUCK_PROBE")
    }

    /// `-OVC_HANG_DECODE`: the decode never completes.
    ///
    /// The fault, injected on purpose. "A `Core.stop()` that never returns" cannot
    /// be produced from outside the process -- it either returns or the app dies --
    /// and it is the one input the stuck-state bug needs. Behind a launch flag, so
    /// no normal run pays for it.
    static var hangsDecode: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_HANG_DECODE")
    }

    /// `-OVC_LLM_RESET`: forget a recorded downgrade before anything loads.
    ///
    /// The model screen has the same button. This exists because the record lives
    /// in the App Group, which survives a reinstall -- so a downgrade recorded by
    /// a bad run outlives the build that recorded it, and the only way back is a
    /// control the tester can reach without tapping through the UI.
    static var resetsLLM: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_LLM_RESET")
    }

    /// `-OVC_MODEL_FETCH <id>`: download one manifest entry at launch.
    ///
    /// The same call the 下載 button makes, so what this exercises is the real path
    /// -- URLSession, the size check, the SHA-256, and the move into `models/`. It
    /// exists because `simctl` cannot tap: without it, "does a phone download and
    /// verify a model" is a question only a human with a phone can answer, and the
    /// answer would arrive on the day a 1.3 GB model is needed.
    static var modelFetch: String? {
        path(after: "-OVC_MODEL_FETCH")
    }

    /// `-OVC_MODEL_VERIFY <id>`: run the manifest's three verification branches
    /// over one installed file, and write the result to `Documents/model-verify.txt`.
    static var modelVerify: String? {
        path(after: "-OVC_MODEL_VERIFY")
    }

    /// `-OVC_TAB <n>`: open on page `n` (0 轉錄 … 4 設定) instead of 轉錄.
    ///
    /// For photographs. `simctl` can install and launch an app but cannot tap it,
    /// so the only way to put a page in front of a camera is to start there. It
    /// never affects a normal launch.
    static var startTab: Int? {
        path(after: "-OVC_TAB").flatMap(Int.init)
    }

    /// `-OVC_THEME <id>`: draw with a named paper, without recording the choice.
    ///
    /// Same reason as `-OVC_TAB`, and one more: the five papers have to be
    /// photographed side by side, and a screenshot run must not leave the tester's
    /// own setting changed. See `ThemeStore.preview`.
    static var themeOverride: String? {
        path(after: "-OVC_THEME")
    }

    private static func path(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag),
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
