import Foundation
import UIKit

/// One fixed transcript, through the real cleanup pass, on the real device.
///
/// The dictation path needs a microphone, a quiet room and someone saying the
/// same sentence twice; none of that is a harness. This is: a known string in,
/// the model's answer, the post-processed answer, and how long it took — written
/// to `Documents/refine.json` and to stdout, which is what
/// `devicectl … --console` captures.
///
/// Reached with `-OVC_REFINE_TEXT "<text>"`. It runs the same `Core.refine` the
/// keyboard's sentence goes through, so the script handling and the model choice
/// are the ones the product uses, not a copy.
enum RefineProbe {
    static func run(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "modelsRoot": SharedStore.modelsRoot.path,
                "recordedDowngrade": LLMPolicy.recorded.map {
                    ["from": $0.from, "to": $0.to, "reason": $0.reason]
                } as Any,
                "requestedModel": LLMPolicy.requestedName,
                "input": text,
                "inputChars": text.count,
                // The recogniser's own output, so a run can prove the conversion
                // is doing something rather than being a no-op.
                "inputTraditional": TextScript.traditional(text),
            ]

            var initError: String?
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
            } catch {
                initError = error.localizedDescription
                out["error"] = initError
            }

            if initError == nil {
                let started = Date()
                do {
                    let raw = try Core.refine(text)
                    out["seconds"] = Date().timeIntervalSince(started)
                    out["raw"] = raw
                    out["traditional"] = TextScript.traditional(raw)
                    out["servedModel"] = Core.lastModelName()
                    let usage = Core.memoryUsage()
                    out["peakRSSMB"] = Double(usage.peak) / 1_048_576
                } catch {
                    out["error"] = error.localizedDescription
                }
            }

            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let path = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent("refine.json")
            try? json.write(to: path)
            print("OVC_REFINE_BEGIN")
            print(String(data: json, encoding: .utf8) ?? "{}")
            print("OVC_REFINE_END")
        }
    }
}
