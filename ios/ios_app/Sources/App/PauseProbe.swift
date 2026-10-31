import Foundation
import UIKit

/// The keyboard's listening buttons, driven without a second pair of hands.
///
/// The buttons themselves are one line of UIKit each; the part that can break is
/// the Darwin notification crossing into an app that may be in the background
/// (Mode 1 and Mode 2 both record that way), and the part that cannot be checked
/// from a script is a tap inside a keyboard extension. These post the *same
/// notifications* `SharedStore.requestPause()`/`requestResume()`/`requestStop()`
/// post, on a timer, and record what the app's own state was a second later.
///
/// Reached with `-OVC_PAUSE_PROBE` (pause and resume) or `-OVC_STOP_PROBE` (stop,
/// and the ending that no longer happens by itself). Both print to stdout (which
/// `devicectl … --console` captures) and write their trace to `Documents`.
@MainActor
enum PauseProbe {
    static func run() {
        var trace: [[String: Any]] = []

        func record(_ step: String) {
            trace.append([
                "step": step,
                "sharedPaused": SharedStore.isPaused,
                "controllerPaused": DictationController.shared.isPaused,
                "phase": DictationController.shared.phase.rawValue,
                "detail": SharedStore.current().detail ?? "",
            ])
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            DictationController.shared.start()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            record("before pause")

            SharedStore.requestPause()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            record("after pause")

            SharedStore.requestResume()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            record("after resume")

            // A pause must not end the sentence: the same dictation keeps going and
            // publishes once, from the tail the user spoke after resuming.
            DictationController.shared.stop()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            record("after stop")

            let out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "trace": trace,
                "published": SharedStore.current().text ?? "",
            ]
            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let url = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent("pause-probe.json")
            try? json.write(to: url)
            print("OVC_PAUSE_BEGIN")
            print(String(data: json, encoding: .utf8) ?? "{}")
            print("OVC_PAUSE_END")
        }
    }

    /// `-OVC_STOP_PROBE`: the stop button, and the ending that is no longer there.
    ///
    /// Two claims in one run. First, that the stop request crosses into the app —
    /// the same Darwin notification the keyboard's button posts — and ends the
    /// dictation. Second, that *nothing else* does: the trace opens with several
    /// seconds of a live recording that receives no audio at all, which is where a
    /// `SilenceGate` used to end the sentence.
    ///
    /// What a simulator cannot show: that gate only fired after 0.35 s of *speech*
    /// followed by 1.2 s of quiet, and a simulator has no microphone to speak into.
    /// So the proof that a real pause no longer cuts a sentence off is the code (the
    /// gate is gone) plus this trace for the first half, and a device run for the
    /// second: say a sentence, wait two seconds, keep talking — the words have to
    /// arrive as one dictation.
    static func runStop() {
        var trace: [[String: Any]] = []

        func record(_ step: String) {
            trace.append([
                "step": step,
                "phase": DictationController.shared.phase.rawValue,
                "detail": SharedStore.current().detail ?? "",
                "asleepFor": DictationController.shared.secondsSinceStateChange,
            ])
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            DictationController.shared.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            record("已開始")

            // Long past the old 1.2 second window. This is the claim: silence does
            // not end a dictation any more.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            record("6 秒沒有聲音之後")

            SharedStore.requestStop()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            record("送出停止請求之後")

            try? await Task.sleep(nanoseconds: 8_000_000_000)
            record("結束之後")

            let out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "trace": trace,
                "stillRecording": DictationController.shared.isRecording,
            ]
            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let url = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent("stop-probe.json")
            try? json.write(to: url)
            print("OVC_STOP_BEGIN")
            print(String(data: json, encoding: .utf8) ?? "{}")
            print("OVC_STOP_END")
        }
    }
}
