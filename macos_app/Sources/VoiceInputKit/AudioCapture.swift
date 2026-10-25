import AVFoundation

/// Microphone-permission helpers.
///
/// The live session throws `.microphoneDenied` rather than prompting, because a
/// library should not raise a system dialog as a side effect of `start()`. A
/// caller that wants the prompt calls these first.
public enum VoiceInputMicrophone {

    /// True when this process may capture audio.
    public static var isAuthorized: Bool { MicrophoneCapture.microphoneAuthorized() }

    /// Requests access. The completion is delivered on an arbitrary thread, as
    /// AVFoundation documents.
    public static func request(_ completion: @escaping (Bool) -> Void) {
        MicrophoneCapture.requestMicrophone(completion)
    }
}

/// Captures microphone audio, converts to 16 kHz mono float32, and delivers
/// chunks.
///
/// Lifted from the app's `AudioCapture.swift` unchanged apart from visibility:
/// the conversion target, the level curve and the tap all behave exactly as the
/// app's dictation does, so a caller of this kit hears the same input.
final class MicrophoneCapture {

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let onSamples: ([Float]) -> Void
    private let onLevel: ((Float) -> Void)?

    init(onSamples: @escaping ([Float]) -> Void, onLevel: ((Float) -> Void)? = nil) {
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    /// Rough loudness for a level meter: RMS in dB mapped onto 0…1 over the
    /// -55…0 dBFS range, which covers speech without pinning the meter.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 55) / 55))
    }

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for microphone access. The callback is delivered on an arbitrary
    /// thread, exactly as AVFoundation documents.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.convertAndEmit(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convertAndEmit(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        onLevel?(Self.level(of: samples))
        onSamples(samples)
    }
}
