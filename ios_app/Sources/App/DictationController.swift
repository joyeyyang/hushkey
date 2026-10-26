import AVFoundation
import SwiftUI
import UIKit

/// One dictation, from the first buffer to the text the keyboard types.
///
/// The keyboard cannot record -- iOS refuses a microphone inside an app extension
/// in CoreMedia, before any permission prompt -- so every dictation happens here,
/// in the containing app, and reaches the keyboard through the App Group. That
/// makes this class the product's whole pipeline:
///
///   mic -> spool to disk -> recogniser -> publish -> keyboard inserts at cursor
///
/// Two details make it feel fast rather than just work. The phase is set to
/// `.recording` before the microphone opens, so the first frame the user sees is
/// already the recording state. And stopping is *automatic* on silence, so the
/// user never has to press stop and then find the back button: they speak, stop,
/// and leave -- the decode runs in the background time they just freed up.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var phase: SharedStore.Phase = .idle
    /// Settled words, accumulated as the recogniser closes utterances.
    @Published private(set) var transcript = ""
    /// The utterance still open, shown while it is being spoken.
    @Published private(set) var live = ""
    /// A failure worth showing on the app's own screen.
    @Published private(set) var error: String?

    /// What the user should read right now, in one string.
    var display: String { transcript + live }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .recording || phase == .transcribing || phase == .refining }

    private let work = DispatchQueue(label: "ovc.dictation", qos: .userInitiated)

    private var mic: MicCapture?
    private var spool: AudioSpool?
    private var gate: SilenceGate?
    private var pollTimer: Timer?
    private var background: UIBackgroundTaskIdentifier = .invalid

    // MARK: start

    /// Loads the recogniser before the first dictation.
    ///
    /// The keyboard's microphone tap opens the app and expects it to be recording
    /// on the first frame. Waiting for a 100 MB model to map would show a second of
    /// "待機" first, so the load happens while the user is still in the app they
    /// were typing in.
    func prewarm() {
        guard SharedStore.hasModels else { return }
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsDir)
                Diagnostics.log.notice("recogniser ready")
            } catch {
                Diagnostics.log.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Begins a dictation from the microphone. Safe to call when one is already
    /// running: the keyboard reopens the app on every microphone tap.
    func start() {
        guard !isBusy else { return }
        reset()
        phase = .recording
        SharedStore.setPhase(.recording, detail: "錄音中…")

        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.fail("需要麥克風權限。請到 設定 › 語音輸入 開啟「麥克風」。")
                    return
                }
                self.openMicrophone()
            }
        }
    }

    private func openMicrophone() {
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsDir)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription) }
                return
            }
            DispatchQueue.main.async { self.attach() }
        }
    }

    private func attach() {
        guard phase == .recording else { return }
        do {
            let spool = try AudioSpool()
            let mic = MicCapture()
            let gate = SilenceGate()

            gate.onFire = { [weak self] reason in
                DispatchQueue.main.async { self?.stop(reason: reason) }
            }
            mic.onSamples = { samples in
                spool.append(samples)
                Core.submit(samples)
                gate.consume(samples)
            }

            try mic.start()
            self.spool = spool
            self.mic = mic
            self.gate = gate
            startPolling()
            Diagnostics.log.notice("dictation started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: stop

    /// Ends the dictation and decodes what is left. `reason` is shown to the user
    /// ("靜音" when they simply stopped talking).
    func stop(reason: String = "") {
        guard phase == .recording else { return }
        pollTimer?.invalidate()
        pollTimer = nil

        mic?.onSamples = nil
        mic?.stop()
        mic = nil
        gate = nil

        decode(accumulated: transcript, reason: reason)
    }

    private func decode(accumulated: String, reason: String) {
        phase = .transcribing
        SharedStore.setPhase(.transcribing, detail: "辨識中…")
        // The user is about to leave for the app they were typing in. This keeps
        // the process alive for the seconds the decode needs.
        beginBackground()

        work.async {
            let final = (try? Core.stop()) ?? ""
            let out = Self.merge(accumulated, final)
            DispatchQueue.main.async {
                self.complete(out, reason: reason)
            }
        }
    }

    private func complete(_ out: String, reason: String) {
        spool?.discard()
        spool = nil
        endBackground()

        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("沒有聽到聲音。再說一次，靠近一點。")
            return
        }

        transcript = out
        live = ""
        phase = .done
        SharedStore.publish(out, detail: reason.isEmpty ? "已辨識" : "已辨識 · \(reason)")
        Diagnostics.log.notice("dictation done: \(out.count, privacy: .public) chars")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func clear() {
        let wasBusy = isBusy
        if wasBusy { stop() }
        reset()
        phase = .idle
        SharedStore.clear()
    }

    private func reset() {
        transcript = ""
        live = ""
        error = nil
    }

    private func fail(_ message: String) {
        pollTimer?.invalidate()
        pollTimer = nil
        mic?.onSamples = nil
        mic?.stop()
        mic = nil
        gate = nil
        spool?.discard()
        spool = nil
        endBackground()
        phase = .failed
        error = message
        SharedStore.setPhase(.failed, detail: message)
        Diagnostics.log.error("dictation failed: \(message, privacy: .public)")
    }

    // MARK: live words

    private func startPolling() {
        pollTimer?.invalidate()
        // Decoding happens on `work`, never on the audio thread: `segments()`
        // closes utterances synchronously and takes a few hundred milliseconds.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.work.async {
                let closed = Core.segments()
                let open = Core.peek()
                guard !closed.isEmpty || !open.isEmpty else { return }
                DispatchQueue.main.async {
                    guard self.phase == .recording else { return }
                    for segment in closed { self.transcript += segment.text }
                    self.live = open
                    SharedStore.setPartial(self.transcript + open)
                }
            }
        }
    }

    // MARK: background time

    private func beginBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "ovc.decode") { [weak self] in
            // Out of time: publishing what we have beats being killed silently.
            DispatchQueue.main.async {
                guard let self else { return }
                self.endBackground()
                if self.phase == .transcribing, !self.transcript.isEmpty {
                    self.complete(self.transcript, reason: "背景時間結束")
                }
            }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: injected audio

    /// Runs the whole pipeline over a file instead of the microphone.
    ///
    /// The simulator has no usable microphone, and the pipeline is the part worth
    /// testing anyway: everything after the sample buffer is identical. Reached
    /// with `-OVC_AUDIO_FILE <path.wav>`, which is also how the regression check
    /// drives a known sentence end to end.
    func runInjected(url: URL, detail: String = "測試音") {
        guard !isBusy else { return }
        reset()
        phase = .recording
        SharedStore.setPhase(.recording, detail: "錄音中…")
        Diagnostics.log.notice("dictation injected: \(url.lastPathComponent, privacy: .public)")

        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsDir)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription) }
                return
            }

            let samples: [Float]
            do {
                samples = try Self.readMono16k(url)
            } catch {
                DispatchQueue.main.async { self.fail("讀不到測試音：\(error.localizedDescription)") }
                return
            }
            guard !samples.isEmpty else {
                DispatchQueue.main.async { self.fail("測試音是空的") }
                return
            }

            // A recovered spool is consumed here. Leaving it would make the next
            // launch transcribe the same sentence again.
            if url.deletingLastPathComponent().standardizedFileURL
                == AudioSpool.directory.standardizedFileURL {
                try? FileManager.default.removeItem(at: url)
            }

            // Written through the same spool as live audio, so the disk path is
            // exercised too -- a bug there would otherwise only show on a phone.
            let spool = try? AudioSpool()
            var index = 0
            let chunk = 1_600  // 100 ms
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                let slice = Array(samples[index..<end])
                spool?.append(slice)
                Core.submit(slice)
                index = end
                if index % (chunk * 10) == 0 {
                    let open = Core.peek()
                    DispatchQueue.main.async {
                        guard self.phase == .recording else { return }
                        self.live = open
                        SharedStore.setPartial(open)
                    }
                }
            }
            spool?.close()

            DispatchQueue.main.async {
                guard self.phase == .recording else { return }
                self.spool = spool
                self.decode(accumulated: "", reason: detail)
            }
        }
    }

    /// Finishes a run the system killed before it could publish.
    ///
    /// This is the other half of the spool's promise. The file exists because iOS
    /// can reclaim the app mid-transcription; on the next launch the pipeline runs
    /// over that audio and hands the text to the keyboard as usual, so the
    /// sentence is late rather than lost.
    func recoverOrphan() {
        guard !isBusy, Diagnostics.injectedAudio == nil else { return }
        AudioSpool.prune()
        let orphans = AudioSpool.orphans()
        guard let newest = orphans.last else { return }
        for stale in orphans.dropLast() {
            try? FileManager.default.removeItem(at: stale)
        }
        Diagnostics.log.notice("recovering spool \(newest.lastPathComponent, privacy: .public)")
        runInjected(url: newest, detail: "補回上次的錄音")
    }

    /// Any WAV/CAF/M4A at any rate, as 16 kHz mono float32.
    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioSpool.sampleRate,
            channels: 1, interleaved: false
        )!
        let input = file.processingFormat

        guard let source = AVAudioPCMBuffer(
            pcmFormat: input, frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ) else { throw CoreError.failed(-1, "無法配置讀取緩衝") }
        try file.read(into: source)

        if input.commonFormat == .pcmFormatFloat32,
           input.sampleRate == target.sampleRate,
           input.channelCount == 1,
           let channel = source.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(source.frameLength)))
        }

        guard let converter = AVAudioConverter(from: input, to: target) else {
            throw CoreError.failed(-1, "無法轉換測試音的格式")
        }
        let capacity = AVAudioFrameCount(
            Double(source.frameLength) * (target.sampleRate / input.sampleRate)
        ) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CoreError.failed(-1, "無法配置轉換緩衝")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: out, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, failure == nil, let channel = out.floatChannelData else {
            throw CoreError.failed(-1, failure?.localizedDescription ?? "轉換失敗")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    // MARK: pieces

    /// `ASR_Stop` returns the whole session, while `transcript` already holds the
    /// utterances closed before it. They usually overlap; keep the longer one.
    private static func merge(_ accumulated: String, _ final: String) -> String {
        if final.isEmpty { return accumulated }
        if accumulated.isEmpty { return final }
        if final.hasPrefix(accumulated) { return final }
        if accumulated.hasPrefix(final) { return accumulated }
        return accumulated + final
    }
}

/// Decides when the user has finished speaking.
///
/// Called from the audio thread on every buffer, so it holds no reference to the
/// controller and does the arithmetic under a lock. Two thresholds: the noise
/// floor measured during the first half second, and a hard silence window. The
/// floor matters -- a quiet room and a train both work without a settings screen.
final class SilenceGate {
    /// Fired once, on the audio thread. The caller hops to main.
    var onFire: ((String) -> Void)?

    private let lock = NSLock()
    private var elapsed: Double = 0
    private var spoken: Double = 0
    private var quiet: Double = 0
    private var floorSample: Double = 1
    private var floorWindow: Double = 0
    private var didFire = false

    private let sampleRate: Double = AudioSpool.sampleRate
    private let silenceWindow: Double = 1.2
    private let minimumSpeech: Double = 0.35
    private let maximumLength: Double = 60

    func consume(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let seconds = Double(samples.count) / sampleRate

        var sum: Double = 0
        for sample in samples { sum += Double(sample * sample) }
        let rms = (sum / Double(samples.count)).squareRoot()

        lock.lock()
        guard !didFire else { lock.unlock(); return }

        elapsed += seconds
        // Learn the room for the first half second, before anything is said.
        if floorWindow < 0.5 {
            floorSample = min(floorSample, rms)
            floorWindow += seconds
        }
        let threshold = min(max(floorSample * 3.0, 0.0045), 0.02)

        if rms > threshold {
            spoken += seconds
            quiet = 0
        } else {
            quiet += seconds
        }

        var reason: String?
        if elapsed >= maximumLength {
            reason = "60 秒上限"
        } else if spoken >= minimumSpeech, quiet >= silenceWindow {
            reason = "靜音"
        }
        if reason != nil { didFire = true }
        lock.unlock()

        // Outside the lock: the callback hops to the main queue, and a lock held
        // across that hop is how a debugger session ends in a mystery hang.
        if let reason { onFire?(reason) }
    }
}
