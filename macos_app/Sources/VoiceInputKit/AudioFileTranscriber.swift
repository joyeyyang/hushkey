import Foundation
import AVFoundation

/// Transcribes an audio file through the same ASR session the microphone path
/// uses.
///
/// Lifted from the app's `AudioFileImporter.swift`, with the async/UI plumbing
/// removed: this version is synchronous and throws, because a caller of a
/// library wants the result or an error, not a completion handler. The decode
/// strategy is unchanged and is the whole reason a three-hour file costs the
/// same memory as a five-second one:
///
///  * AVFoundation decodes the container to LPCM at the source's own rate,
///  * `AVAudioConverter` resamples to 16 kHz mono (the same class `AudioCapture`
///    uses, so compressed files and odd rates take one code path), and
///  * audio is streamed to the engine in 5 s chunks, draining segments at every
///    boundary — which is also what keeps the engine far below its session cap.
enum FileTranscriber {

    // MARK: - Tuning

    /// 5 s of 16 kHz mono is 80,000 floats (320 KB), and that is the whole audio
    /// footprint: the reader returns one sample buffer at a time and `pending`
    /// is handed off at every boundary. No overlap between chunks, deliberately:
    /// one session spans the file and its VAD segmenter keeps state, so
    /// re-sending a tail would decode it twice.
    private static let chunkSeconds: Double = 5
    private static let targetRate: Double = 16_000

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)

    /// Decode `url` end to end and return raw + refined text.
    ///
    /// `progress` is called with a 0…1 fraction and a short status line. It runs
    /// on the calling thread — decode is synchronous — so a UI caller should
    /// hand the whole call to a background queue and marshal the callback.
    static func transcribe(
        url: URL,
        config: VoiceInputConfig,
        progress: ((Double, String) -> Void)?
    ) throws -> VoiceInputResult {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw VoiceInputError.fileUnreadable(url.lastPathComponent)
        }
        guard let target = targetFormat else {
            throw VoiceInputError.decoderUnavailable("no 16 kHz mono format")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw VoiceInputError.noAudioTrack
        }
        let seconds = asset.duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw VoiceInputError.emptyAudio }
        emit(0, "reading audio", progress)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw VoiceInputError.decoderUnavailable("reader: \(error.localizedDescription)") }

        // LPCM at the source's own rate and channel count; getting to 16 kHz
        // mono is the resampler's job.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw VoiceInputError.unsupportedFormat("not LPCM-decodable") }
        reader.add(output)
        guard reader.startReading() else {
            throw VoiceInputError.decoderUnavailable("start: \(reader.error?.localizedDescription ?? "unknown")")
        }
        defer { reader.cancelReading() }

        // Loading is idempotent in the core, and doing it here is what lets a
        // dropped file work before the user has ever dictated.
        try CoreABI.loadASR()
        try CoreABI.startASR()
        // Set only after the start succeeded: a session this call did not open
        // belongs to someone else, and stopping it would kill their recording.
        var sessionOwned = true
        // Any exit that is not the normal finish must end the session, or the
        // next recording is refused with "session already active".
        defer { if sessionOwned { _ = try? CoreABI.stopASR() } }

        let resampler = AudioResampler(target: target)
        let chunkFrames = Int(chunkSeconds * targetRate)
        let totalFrames = max(chunkFrames, Int(seconds * targetRate))
        var pending: [Float] = []
        pending.reserveCapacity(chunkFrames + 4_096)
        var segments: [Utterance] = []
        var decoded = 0
        var rejected = 0
        var reported = -1.0

        while let sample = output.copyNextSampleBuffer() {
            guard let floats = resampler.samples(from: sample), !floats.isEmpty else {
                rejected += 1
                continue
            }
            pending.append(contentsOf: floats)
            decoded += floats.count
            if pending.count >= chunkFrames {
                try CoreABI.submit(pending)
                drain(into: &segments)
                pending.removeAll(keepingCapacity: true)
            }
            let fraction = min(0.99, Double(decoded) / Double(totalFrames))
            if fraction - reported >= 0.01 {
                reported = fraction
                emit(fraction, "transcribing \(Int(fraction * 100))%", progress)
            }
        }

        if reader.status == .failed {
            throw VoiceInputError.decoderUnavailable(reader.error?.localizedDescription ?? "reader failed")
        }
        guard decoded > 0 else {
            throw rejected == 0 ? VoiceInputError.emptyAudio : VoiceInputError.unsupportedFormat("no decodable frames")
        }
        if !pending.isEmpty {
            try CoreABI.submit(pending)
            drain(into: &segments)
            pending.removeAll(keepingCapacity: true)
        }

        emit(0.99, "polishing transcript", progress)
        let stopText: String
        do {
            stopText = try CoreABI.stopASR()
            sessionOwned = false
        } catch {
            throw error
        }
        // `ASR_Stop` decodes the final utterance itself, so one more drain puts
        // the closing sentence in.
        drain(into: &segments)

        let joined = Text.join(segments.map(\.text))
        let raw = joined.isEmpty ? stopText.trimmingCharacters(in: .whitespacesAndNewlines) : joined
        let refined = Refiner.refine(raw: raw, config: config)
        emit(1, "done", progress)
        return VoiceInputResult(raw: raw, refined: refined, segments: segments)
    }

    /// `takeSegments` is what makes the engine decode what was submitted, and
    /// per-chunk draining is also what keeps it far below its session cap. A
    /// failure here costs text, not the import: the next drain returns whatever
    /// is still undelivered.
    private static func drain(into segments: inout [Utterance]) {
        segments.append(contentsOf: (try? CoreABI.takeSegments()) ?? [])
    }

    private static func emit(_ value: Double, _ status: String, _ handler: ((Double, String) -> Void)?) {
        handler?(max(0, min(1, value)), status)
    }
}

/// Turns AVFoundation's PCM into the engine's 16 kHz mono `[Float]`.
///
/// One instance per import on purpose: `AVAudioConverter` carries filter state
/// between buffers, so building it per buffer would click at every seam.
private final class AudioResampler {

    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private var sourceChannels: AVAudioChannelCount = 0

    init(target: AVAudioFormat) {
        self.target = target
    }

    /// Nil when the buffer cannot be read or converted; the caller counts those
    /// rather than trusting a malformed frame to be impossible.
    func samples(from sample: CMSampleBuffer) -> [Float]? {
        guard let format = Self.format(of: sample) else { return nil }
        if converter == nil || format.sampleRate != sourceRate || format.channelCount != sourceChannels {
            converter = AVAudioConverter(from: format, to: target)
            sourceRate = format.sampleRate
            sourceChannels = format.channelCount
        }
        guard let converter, let input = Self.buffer(sample, format: format) else { return nil }

        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard failure == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    /// From the buffer's own stream description, not
    /// `AVAudioFormat(commonFormat:…)`, which cannot describe a buffer whose
    /// sample rate is not 16 kHz. Both initializers refuse more than two
    /// channels without a channel layout, so a surround file comes back nil here
    /// and is reported as unsupported rather than decoded with the wrong layout.
    private static func format(of sample: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        var copy = asbd
        return AVAudioFormat(streamDescription: &copy)
    }

    /// The reader was asked for interleaved float, so one AudioBuffer holds every
    /// channel and this is a single memcpy.
    private static func buffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, format.isInterleaved,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let source = list.mBuffers.mData,
              let destination = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        memcpy(destination, source, Int(frames) * Int(format.channelCount) * MemoryLayout<Float>.size)
        return out
    }
}
