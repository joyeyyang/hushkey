import AppKit
import Foundation

/// Coordinates setup -> hotkey -> mic -> core ASR -> text injection.
/// Core and audio calls run on coreQueue; all UI updates run on the main thread.
final class AppController {
    private let hud = HUDWindow()
    private var capture: AudioCapture?
    private var hotkey: Hotkey?
    private var active = false
    private var ready = false
    private let coreQueue = DispatchQueue(label: "ovc.core")

    func start() {
        // Make sure no HUD is on screen during model setup; it appears only on hotkey actions.
        hud.hide()
        hotkey = Hotkey { [weak self] in self?.toggle() }
        if hotkey?.register() != true {
            ModelInstaller.log("Option+Space hotkey could not be registered")
        }
        coreQueue.async {
            do {
                let dir = try Self.modelsDirectory { message in
                    ModelInstaller.log(message)
                }
                try Core.initialize(modelsDir: dir.path)
                try Core.loadASR()
                ModelInstaller.log("core ready: \(dir.path)")
                DispatchQueue.main.async {
                    self.ready = true
                    ModelInstaller.log("ready: press Option+Space to dictate")
                    if let wav = SelfTest.wavPath { self.runSelfTest(wav) }
                }
            } catch {
                ModelInstaller.log("setup failed: \(error)")
                DispatchQueue.main.async { self.ready = false }
            }
        }
    }

    /// Developer override: OVC_MODELS points at an existing models directory (no download).
    /// Otherwise models live in Application Support, or $OVC_DATA_DIR/models if set (testing).
    static func modelsDirectory(progress: @escaping (String) -> Void) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["OVC_MODELS"] {
            return URL(fileURLWithPath: dir)
        }
        let base: URL
        if let dataDir = env["OVC_DATA_DIR"] {
            base = URL(fileURLWithPath: dataDir)
        } else {
            base = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OfflineVoiceAssistant")
        }
        let root = base.appendingPathComponent("models")
        try ModelInstaller.ensureInstalled(root: root, progress: progress)
        return root
    }

    /// Test-only: run the dictation path on a WAV file instead of the microphone, then exit.
    private func runSelfTest(_ path: String) {
        let samples: [Float]
        do {
            samples = try SelfTest.readWav(URL(fileURLWithPath: path))
        } catch {
            ModelInstaller.log("selftest: \(error)")
            exit(2)
        }
        ModelInstaller.log("selftest: \(samples.count) samples (\(samples.count / 16_000)s) from \(path)")
        active = true
        coreQueue.async {
            do { try Core.startASR() } catch {
                ModelInstaller.log("selftest: startASR failed: \(error)")
                exit(3)
            }
            // Feed in 1-second blocks, as the microphone tap would.
            let block = 16_000
            var i = 0
            while i < samples.count {
                let end = min(i + block, samples.count)
                do { try Core.submit(Array(samples[i..<end])) } catch {
                    ModelInstaller.log("selftest: submit failed: \(error)")
                    exit(3)
                }
                i = end
            }
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func toggle() {
        DispatchQueue.main.async {
            if self.active { self.finish() } else { self.begin() }
        }
    }

    private func begin() {
        guard ready else {
            hud.show(text: "Still preparing models…")
            return
        }
        guard AudioCapture.microphoneAuthorized() else {
            AudioCapture.requestMicrophone { granted in
                DispatchQueue.main.async {
                    self.hud.show(text: granted
                        ? "Microphone granted; press Option+Space again"
                        : "Microphone permission denied (System Settings > Privacy > Microphone)")
                }
            }
            return
        }
        coreQueue.async {
            do { try Core.startASR() } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
                return
            }
            DispatchQueue.main.async {
                self.active = true
                self.hud.show(text: "Listening…")
                let cap = AudioCapture { [weak self] samples in
                    self?.coreQueue.async { try? Core.submit(samples) }
                }
                self.capture = cap
                do { try cap.start() } catch {
                    self.hud.show(text: "Microphone error: \(error)")
                    self.active = false
                }
            }
        }
    }

    private func finish() {
        capture?.stop()
        capture = nil
        active = false
        hud.show(text: "Transcribing…")
        coreQueue.async {
            let raw: String
            do {
                raw = try Core.stopASR()
            } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
                return
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if SelfTest.wavPath != nil { ModelInstaller.log("selftest asr: \(trimmed)") }
            guard !trimmed.isEmpty else {
                DispatchQueue.main.async { self.deliver("") }
                return
            }
            DispatchQueue.main.async { self.hud.show(text: "Polishing...") }
            // LLM polish is best-effort: any failure falls back to the raw transcript.
            let final: String
            do {
                let polished = try Core.refine(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
                final = polished.isEmpty ? trimmed : polished
            } catch {
                ModelInstaller.log("refine failed, using raw transcript: \(error)")
                final = trimmed
            }
            DispatchQueue.main.async { self.deliver(final) }
        }
    }

    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if SelfTest.wavPath != nil {
            // Self-test: report the final text and exit instead of pasting.
            ModelInstaller.log("selftest result: \(trimmed)")
            exit(trimmed.isEmpty ? 4 : 0)
        }
        guard !trimmed.isEmpty else {
            hud.show(text: "No speech detected")
            return
        }
        switch TextInjector.insert(trimmed) {
        case .pasted:
            hud.show(text: trimmed)
        case let .copiedOnly(reason):
            hud.show(text: "\(trimmed)\n(\(reason))")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
