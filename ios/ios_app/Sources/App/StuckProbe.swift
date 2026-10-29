import Foundation
import UIKit

/// Records what the pipeline's phase does when a decode never comes back.
///
/// The user's report was "the microphone will not press". Nothing was wrong with the
/// microphone: `isBusy` is true for `.recording`, `.transcribing` and `.refining`, and
/// `RecorderTab` disables the button for every busy phase except `.recording` — so
/// the state that hurts is a phase that never ends, and once it is there every
/// later tap returns in silence (`start()` guards on `!isBusy`).
///
/// The way in is a launch: `prepare()` finds a leftover spool from a run the system
/// killed, which puts the phase on `.transcribing`, and if that decode never returns
/// the phase is never left. `-OVC_HANG_DECODE` supplies exactly that decode, so the
/// whole chain below is the real one — no synthetic state:
///
///   prepare() → recoverOrphan() → runInjected() → decode() → (never completes)
///
/// The probe samples the phase every two seconds, then ends by pressing the button
/// (`start()`) and recording whether the press was acted on or swallowed.
///
/// Reached with `-OVC_STUCK_PROBE`; writes `Documents/stuck-probe.json` and prints
/// the same JSON to stdout.
@MainActor
enum StuckProbe {
    /// Longer than any deadline the pipeline has, so a "still stuck" verdict is about
    /// the pipeline and not about the probe giving up early.
    private static let observationWindow: TimeInterval = 40
    /// How often the phase is sampled while waiting.
    private static let sampleInterval: TimeInterval = 2

    static func run() {
        let dictation = DictationController.shared
        let started = Date()

        func snapshot(_ step: String) -> [String: Any] {
            [
                "step": step,
                "atSeconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
                "phase": dictation.phase.rawValue,
                "isBusy": dictation.isBusy,
                "isRecording": dictation.isRecording,
                // The button's own rule, quoted from `RecorderTab`:
                //   .disabled(dictation.isBusy && !dictation.isRecording)
                "buttonDisabled": dictation.isBusy && !dictation.isRecording,
                "transcript": dictation.transcript,
                "display": dictation.display,
                "error": dictation.error ?? "",
                "sharedPhase": SharedStore.current().phase.rawValue,
                "recovering": dictation.isRecovering,
            ]
        }

        Task { @MainActor in
            var trace: [[String: Any]] = []

            // The launch's own recovery starts from `prepare()` on the first
            // `onAppear`, so a few seconds are needed before the first look.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            trace.append(snapshot("recovery started"))

            // Sample until the phase leaves `.transcribing`, or the window closes.
            let deadline = Date().addingTimeInterval(observationWindow)
            var left = dictation.phase != .transcribing
            while !left && Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1_000_000_000))
                trace.append(snapshot("waiting"))
                left = dictation.phase != .transcribing
            }

            // The press. Whatever the phase is now, this is the user's next move --
            // and being ignored is the second half of the complaint.
            let before = dictation.phase.rawValue
            dictation.start()
            let afterPress = snapshot("after pressing the microphone")
            trace.append(afterPress)

            let out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "hangedDecode": Diagnostics.hangsDecode,
                "observationSeconds": observationWindow,
                "leftTranscribing": left,
                "phaseBeforePress": before,
                "pressWasActedOn": (afterPress["phase"] as? String) != before,
                "finalPhase": dictation.phase.rawValue,
                "finalButtonDisabled": dictation.isBusy && !dictation.isRecording,
                "finalError": dictation.error ?? "",
                "trace": trace,
            ]

            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let url = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent("stuck-probe.json")
            try? json.write(to: url)
            print("OVC_STUCK_BEGIN")
            print(String(data: json, encoding: .utf8) ?? "{}")
            print("OVC_STUCK_END")
            Diagnostics.log.notice(
                "stuck probe done: leftTranscribing=\(left, privacy: .public) finalPhase=\(dictation.phase.rawValue, privacy: .public)"
            )
        }
    }
}
