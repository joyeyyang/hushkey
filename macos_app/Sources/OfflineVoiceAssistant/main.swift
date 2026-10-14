import AppKit
import Foundation

/// Coordinates hotkey -> mic -> core ASR -> text injection.
/// Core and audio calls run off the main thread; UI updates run on the main thread.
final class AppController {
    private let hud = HUDWindow()
    private var capture: AudioCapture?
    private var hotkey: Hotkey?
    private var active = false
    private let coreQueue = DispatchQueue(label: "ovc.core")
    private let modelsDir: String

    init(modelsDir: String) {
        self.modelsDir = modelsDir
    }

    func start() {
        coreQueue.async { [modelsDir] in
            do {
                try Core.initialize(modelsDir: modelsDir)
                try Core.loadASR()
            } catch {
                DispatchQueue.main.async { self.hud.show(text: "Model load failed: \(error)") }
            }
        }
        hotkey = Hotkey { [weak self] in self?.toggle() }
        if hotkey?.register() != true {
            hud.show(text: "Option+Space hotkey could not be registered")
        }
    }

    private func toggle() {
        DispatchQueue.main.async {
            if self.active { self.finish() } else { self.begin() }
        }
    }

    private func begin() {
        guard AudioCapture.microphoneAuthorized() else {
            AudioCapture.requestMicrophone { granted in
                DispatchQueue.main.async {
                    self.hud.show(text: granted ? "Microphone granted; press Option+Space again" : "Microphone permission denied (System Settings > Privacy > Microphone)")
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
            do {
                let text = try Core.stopASR()
                DispatchQueue.main.async { self.deliver(text) }
            } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
            }
        }
    }

    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

let modelsDirectory = ProcessInfo.processInfo.environment["OVC_MODELS"]
    ?? (FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OfflineVoiceAssistant/models").path)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController(modelsDir: modelsDirectory)
controller.start()
app.run()
