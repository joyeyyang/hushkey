import Foundation
import UIKit

/// The keyboard's 修改的提示詞 round trip, run from inside the app.
///
/// Reached with `-OVC_KB_EDIT_PROBE "<instruction>"`. It writes the request the
/// panel writes (`SharedStore.requestEdit`), then waits for the two things the
/// panel waits for: the acknowledgement and the answer. Both are what the panel
/// acts on, so running them here exercises the real path -- the Darwin
/// notification into `KeyboardEdit`, the consumption that stops a second channel
/// running the model twice, `LLM_EditText`, and the guardrail.
///
/// The result goes to `Documents/keyboard-edit.json` and to stdout, which is
/// what `simctl launch --console` captures. A phone with models installed gives
/// the whole answer; a simulator without them gives the refusal, which is also
/// worth seeing -- "the app heard you and cannot help" must not look like "the
/// app is not running".
enum KeyboardEditProbe {

    /// One sentence with two facts, so an edit has something to change and
    /// something to leave alone.
    private static let draft = "明天下午三點跟小林開會，討論第四季時程"

    static func run(instruction: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "modelsRoot": SharedStore.modelsRoot.path,
                "hasModels": SharedStore.hasModels,
                "hasLLM": SharedStore.hasLLM,
                "draft": draft,
                "instruction": instruction,
            ]
            // `prepare()` registers the observer and runs on the first view; a
            // request written before that is a request nobody is listening for.
            Thread.sleep(forTimeInterval: 2.0)

            let start = Date()
            let seq = SharedStore.requestEdit(draft: draft, instruction: instruction)
            out["seq"] = seq

            var ack: Double?
            var result: SharedStore.EditResult?
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if ack == nil, SharedStore.editAckedSeq >= seq {
                    ack = Date().timeIntervalSince(start)
                    print("kb-edit: acked after \(String(format: "%.2f", ack!))s")
                }
                if let answer = SharedStore.editResult(for: seq) {
                    result = answer
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            let elapsed = Date().timeIntervalSince(start)
            out["ackedAfter"] = ack ?? -1
            out["elapsed"] = elapsed
            out["ack"] = SharedStore.editAckedSeq
            out["text"] = result?.text
            out["error"] = result?.error
            out["answered"] = result != nil

            // What the keyboard does once it has the answer, so a later launch
            // does not treat this probe's answer as one still to be applied.
            if result != nil { SharedStore.markEditApplied(seq) }

            let summary: String
            if let result {
                summary = result.text.map { "text: \($0)" } ?? "error: \(result.error ?? "-")"
            } else {
                summary = "no answer within \(Int(elapsed))s"
            }
            print("kb-edit: seq \(seq), acked \(ack.map { String(format: "%.2f", $0) } ?? "never"), \(summary)")

            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("keyboard-edit.json")
            if let data = try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: url)
            }
        }
    }
}
