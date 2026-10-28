import Foundation
import UIKit

/// The keyboard's pause and resume buttons, driven without a second pair of hands.
///
/// The buttons themselves are one line of UIKit each; the part that can break is
/// the Darwin notification crossing into an app that may be in the background
/// (Mode 1 and Mode 2 both record that way), and the part that cannot be checked
/// from a script is a tap inside a keyboard extension. This posts the *same two
/// notifications* `SharedStore.requestPause()`/`requestResume()` post, on a timer,
/// and records what the app's own state was one second later.
///
/// Reached with `-OVC_PAUSE_PROBE`. Prints to stdout (which
/// `devicectl … --console` captures) and writes `Documents/pause-probe.json`.
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
}
