import SwiftUI
import UniformTypeIdentifiers

@main
struct OVCApp: App {
    init() {
        // `-OVC_LLM_RESET` first: it has to land before anything can load a model,
        // and a recorded downgrade would otherwise be applied by the first
        // `Core.initialize` this launch performs.
        if Diagnostics.resetsLLM {
            LLMPolicy.clear()
        }

        // Before any view exists, so a launch that never reaches one is still readable.
        Diagnostics.emit()

        // The screenshot flags. Both are no-ops on a normal launch, and neither
        // writes anything down.
        if let id = Diagnostics.themeOverride {
            ThemeStore.shared.preview(id)
        }

        // `-OVC_AUDIO_FILE <path>` runs the whole pipeline over a file instead of
        // the microphone. The simulator has no usable microphone, and everything
        // after the sample buffer is the part worth testing.
        if let path = Diagnostics.injectedAudio {
            Task { @MainActor in
                DictationController.shared.prewarm()
                // Lets a text field take focus (and the keyboard appear) first.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                DictationController.shared.runInjected(url: URL(fileURLWithPath: path))
            }
        } else if Diagnostics.startsRecording {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                DictationController.shared.start()
            }
        }

        if let instruction = Diagnostics.keyboardEditInstruction {
            KeyboardEditProbe.run(instruction: instruction)
        }

        if Diagnostics.probesPause {
            Task { @MainActor in PauseProbe.run() }
        }

        if Diagnostics.probesStuck {
            Task { @MainActor in StuckProbe.run() }
        }

        if let text = Diagnostics.refineText {
            RefineProbe.run(text)
        }

        if Diagnostics.runsDeviceBench {
            DeviceBench.run()
        }

        // `-OVC_MERGE_PROBE`: the overlapping-transcript rule, over the exact
        // pair that produced a doubled sentence -- the two sides of the pipeline
        // spell the same words differently when a boundary is not Chinese to
        // Chinese (the core inserts a space, this side concatenates), and the old
        // code appended them. A dictation cannot reproduce it on this recogniser,
        // which normalises English and digits to Chinese, so the rule is checked
        // directly rather than through audio that will not exercise it.
        if ProcessInfo.processInfo.arguments.contains("-OVC_SRT_PROBE") {
            Self.runSrtProbe()
        }

        if ProcessInfo.processInfo.arguments.contains("-OVC_MERGE_PROBE") {
            let pairs = [
                ("開會用Notion記錄", "開會用 Notion 記錄"),
                ("今天下午三點要開會", "今天下午三點要開會"),
                ("", "只有核心的話"),
                ("只有這一邊", ""),
            ]
            for (accumulated, final) in pairs {
                Diagnostics.log.notice(
                    "merge: \(DictationController.merge(accumulated, final), privacy: .public)"
                )
            }
        }
    }

    /// `-OVC_SRT_PROBE`: the subtitle file over three synthetic dictations.
    ///
    /// The timecodes are the part worth checking, and they cannot be checked by
    /// eye on a phone: an SRT is read by machines, and a wrong origin -- the epoch,
    /// midnight, or the first cue's *finish* time instead of its start -- still
    /// looks exactly like a timecode. The three entries are also chosen for the
    /// edges: one with a measured duration, one with none (the half-second floor),
    /// and one with a newline in it (an SRT cue is one line).
    private static func runSrtProbe() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Newest first, the order `History.all()` returns.
        let entries = [
            HistoryEntry(id: UUID(), text: "第三句\n有換行。", date: base.addingTimeInterval(90.5),
                         detail: "", model: "", seconds: 6),
            HistoryEntry(id: UUID(), text: "第二句沒有時間。", date: base.addingTimeInterval(70),
                         detail: "", model: "", seconds: 0),
            HistoryEntry(id: UUID(), text: "今天下午三點要開會。", date: base.addingTimeInterval(12),
                         detail: "", model: "", seconds: 4),
        ]
        let document = History.srt(entries)
        // Written to `Documents`, not only printed: `simctl launch --console` did
        // not deliver this app's stdout on the simulator this was checked on, and a
        // probe nobody can read is not a check. Same reason `DeviceBench` writes
        // `bench.json` as well as printing.
        let url = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("srt-probe.srt")
        try? document.write(to: url, atomically: true, encoding: .utf8)
        print("OVC_SRT_BEGIN")
        print(document, terminator: "")
        print("OVC_SRT_END")
        Diagnostics.log.notice("srt probe written to \(url.path, privacy: .public)")
    }

    private static var isKeyboardProbe: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_KB_PROBE")
    }

    var body: some Scene {
        WindowGroup {
            if Diagnostics.isSmokeRun {
                SmokeView()
            } else if Self.isKeyboardProbe {
                KeyboardProbeView()
            } else {
                RootView()
            }
        }
    }
}

/// The three M6 numbers, measured on the phone being asked.
///
/// Every call to `Core.refine` loads the weights, generates, and drops them --
/// there is no warm cache to time separately on iOS -- so a single call is both
/// "模型載入秒數" and "整理耗時" glued together. The two samples below are the
/// same call twice, which is what the numbers are for: a second sample tells
/// apart "this phone is slow" from "this run was unlucky".
enum DeviceBench {
    /// Two sentences: one the product's own regression uses, and one longer
    /// enough to make the generation time visible next to the load.
    private static let texts = [
        "今天下午三點要跟王經理開會，討論下個季度的預算。",
        "下週一上午十點前把預算表寄給王經理，副本給財務部，並提醒他上次的會議紀錄還沒簽回。",
    ]

    static func run() {
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: Any] = [
                "at": ISO8601DateFormatter().string(from: Date()),
                "device": UIDevice.current.model,
                "system": ProcessInfo.processInfo.operatingSystemVersionString,
                "modelsRoot": SharedStore.modelsRoot.path,
                "hasModels": SharedStore.hasModels,
                "installed": LLMPolicy.installed.map { ["name": $0.name, "bytes": $0.bytes] },
                "recordedDowngrade": LLMPolicy.recorded.map {
                    ["from": $0.from, "to": $0.to, "reason": $0.reason]
                } as Any,
            ]

            // ASR, on its own: this is the load the keyboard waits for first.
            let t0 = Date()
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                out["asrLoadSeconds"] = Date().timeIntervalSince(t0)
            } catch {
                out["asrLoadError"] = error.localizedDescription
            }
            let afterAsr = Core.memoryUsage()
            out["peakAfterAsrMB"] = Double(afterAsr.peak) / 1_048_576
            out["modelsAfterAsrMB"] = Double(afterAsr.models) / 1_048_576

            var samples: [[String: Any]] = []
            for text in texts {
                let started = Date()
                let refined = (try? Core.refine(text)) ?? ""
                let seconds = Date().timeIntervalSince(started)
                let usage = Core.memoryUsage()
                samples.append([
                    "inputChars": text.count,
                    "seconds": seconds,
                    "output": refined,
                    "servedModel": Core.lastModelName(),
                    "peakRSSMB": Double(usage.peak) / 1_048_576,
                    "modelsMB": Double(usage.models) / 1_048_576,
                ])
            }
            out["refine"] = samples

            let json = (try? JSONSerialization.data(
                withJSONObject: out, options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let path = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent("bench.json")
            try? json.write(to: path)
            // Also on stdout, which `devicectl device process launch --console`
            // captures: the file needs a working copy step, this does not.
            let flat = String(data: json, encoding: .utf8) ?? "{}"
            print("OVC_BENCH_BEGIN")
            print(flat)
            print("OVC_BENCH_END")
            Diagnostics.log.notice("bench written to \(path.path, privacy: .public)")
        }
    }
}
