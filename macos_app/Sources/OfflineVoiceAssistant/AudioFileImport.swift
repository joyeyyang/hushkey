import AppKit
import AVFoundation

/// Transcribes an audio file through the same ASR session the microphone uses.
///
/// The engine holds one session at a time, so this class takes that session for
/// the length of an import and refuses to start while anything else holds it.
/// Audio is decoded by AVFoundation, resampled with `AVAudioConverter` (the
/// conversion `AudioCapture` already uses) and streamed in 5 s chunks, so a
/// three-hour file costs the same memory as a five-second one.
final class AudioFileImporter {

    struct AudioImportResult {
        /// Joined speech, no speaker labels — the shape the live path pastes.
        let text: String
        /// Seconds actually decoded, not the container's claimed length.
        let duration: TimeInterval
        /// Engine order; indices continue across chunks because the session does.
        let segments: [TranscriptSegment]
    }

    enum AudioImportError: Error, LocalizedError {
        /// A live recording or another import owns the engine's single session.
        case engineBusy
        case cancelled
        case fileUnreadable(String)
        case unsupportedFormat
        case noAudioTrack
        case emptyAudio
        case decoderUnavailable(String)
        case modelsNotReady
        case engine(String)

        /// Only these earn a retry: another process holding the file, or
        /// AVFoundation or the engine not being ready yet. A wrong codec or a
        /// missing track fails identically the second time.
        var isTransient: Bool {
            switch self {
            case .fileUnreadable, .decoderUnavailable, .engine: return true
            case .engineBusy, .cancelled, .unsupportedFormat, .noAudioTrack,
                 .emptyAudio, .modelsNotReady: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .engineBusy: return "正在錄音或已有檔案在匯入，請先結束目前的錄音再匯入音訊檔。"
            case .cancelled: return "已取消匯入。"
            case let .fileUnreadable(name): return "無法讀取「\(name)」，檔案可能正被其他程式使用，或尚未下載完成。"
            case .unsupportedFormat: return "無法解碼這個音訊格式，請改用 WAV、M4A、MP3、AIFF 或 CAF。"
            case .noAudioTrack: return "這個檔案沒有音訊軌，請確認選到的是音訊檔。"
            case .emptyAudio: return "音訊檔是空的或長度為零，沒有可辨識的內容。"
            case .decoderUnavailable: return "音訊解碼器暫時無法使用，請稍後再試一次。"
            case .modelsNotReady: return "語音模型還沒載入完成，請等模型就緒後再匯入。"
            case .engine: return "語音引擎發生錯誤，請稍後再試一次。"
            }
        }
    }

    // MARK: - Tuning

    /// 5 s of 16 kHz mono is 80,000 floats (320 KB), and that is the whole audio
    /// footprint of an import: the reader returns one sample buffer at a time,
    /// the resampler keeps one converted buffer, and `pending` is handed to the
    /// engine at every boundary, where `drain` empties the engine's queue too.
    /// Peak is ~3 MB here, against 230 MB for an hour held as one Float array.
    ///
    /// No overlap between chunks, deliberately: overlapping only helps when each
    /// slice is its own ASR session. Here one session spans the file and its VAD
    /// segmenter keeps state, so re-sending a tail would decode it twice.
    private static let chunkSeconds: Double = 5
    private static let targetRate: Double = 16_000
    private static let maxAttempts = 3
    /// Delay before attempt 2, then before attempt 3.
    private static let backoff: [TimeInterval] = [0.5, 1.0, 2.0]

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
    )

    // MARK: - Ownership

    /// Process-wide, like the session it protects: a second importer instance
    /// would otherwise walk into `ASR_Start` after decoding part of the file.
    private static let busyLock = NSLock()
    private static var importing = false

    static var isImporting: Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        return importing
    }

    /// A live recording is not visible here — the engine's "session already
    /// active" error is what catches that one.
    var isBusy: Bool { Self.isImporting }

    private let queue = DispatchQueue(label: "ovc.audiofileimport", qos: .userInitiated)
    private let stateLock = NSLock()
    private var cancelledFlag = false

    // MARK: - Public API

    func importFile(at url: URL,
                    onProgress: @escaping (Double) -> Void,
                    onStatus: @escaping (String) -> Void,
                    completion: @escaping (Result<AudioImportResult, AudioImportError>) -> Void) {
        guard Self.claimEngine() else {
            ModelInstaller.log("audio import: refused, the engine already has a session")
            finish(.failure(.engineBusy), completion)
            return
        }
        setCancelled(false)
        queue.async {
            self.run(url: url, onProgress: onProgress, onStatus: onStatus, completion: completion)
        }
    }

    /// Stops feeding at the next chunk boundary. The worker ends the session
    /// itself, because `ASR_Stop` must not race `ASR_Submit`.
    func cancel() {
        guard Self.isImporting else { return }
        setCancelled(true)
        ModelInstaller.log("audio import: cancel requested")
    }

    // MARK: - Attempts

    private func run(url: URL,
                     onProgress: @escaping (Double) -> Void,
                     onStatus: @escaping (String) -> Void,
                     completion: @escaping (Result<AudioImportResult, AudioImportError>) -> Void) {
        defer { Self.releaseEngine() }
        var attempt = 1
        while true {
            if isCancelled {
                finish(.failure(.cancelled), completion)
                return
            }
            ModelInstaller.log("audio import: attempt \(attempt)/\(Self.maxAttempts) \(url.lastPathComponent)")
            do {
                let result = try importOnce(url: url, onProgress: onProgress, onStatus: onStatus)
                ModelInstaller.log("audio import: done \(url.lastPathComponent) "
                    + "segments=\(result.segments.count) seconds=\(String(format: "%.1f", result.duration))")
                emit(1, onProgress)
                emit("完成", onStatus)
                finish(isCancelled ? .failure(.cancelled) : .success(result), completion)
                return
            } catch let error as AudioImportError {
                ModelInstaller.log("audio import: attempt \(attempt) failed — \(error)")
                guard error.isTransient, attempt < Self.maxAttempts, !isCancelled else {
                    finish(.failure(isCancelled ? .cancelled : error), completion)
                    return
                }
                let delay = Self.backoff[min(attempt - 1, Self.backoff.count - 1)]
                ModelInstaller.log("audio import: retrying in \(delay)s")
                emit("讀取失敗，第 \(attempt + 1) 次嘗試…", onStatus)
                guard sleepCancellable(delay) else {
                    finish(.failure(.cancelled), completion)
                    return
                }
                attempt += 1
            } catch {
                // importOnce only throws AudioImportError; this guards an edit
                // that forgets to wrap something.
                ModelInstaller.log("audio import: unexpected \(error)")
                finish(.failure(.engine("\(error)")), completion)
                return
            }
        }
    }

    // MARK: - One attempt

    private func importOnce(url: URL,
                            onProgress: @escaping (Double) -> Void,
                            onStatus: @escaping (String) -> Void) throws -> AudioImportResult {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioImportError.fileUnreadable(url.lastPathComponent)
        }
        guard let target = Self.targetFormat else {
            throw AudioImportError.decoderUnavailable("no 16 kHz mono format")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        // `tracks` and `duration` are the pre-macOS-13 accessors. Their async
        // replacements need a Task, and this method already runs off-main.
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioImportError.noAudioTrack
        }
        let seconds = asset.duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw AudioImportError.emptyAudio }
        emit("讀取音訊…", onStatus)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AudioImportError.decoderUnavailable("reader: \(error.localizedDescription)") }

        // LPCM at the source's own rate and channel count: getting to 16 kHz
        // mono is the resampler's job, as in AudioCapture, so compressed files
        // and odd sample rates take one code path.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw AudioImportError.unsupportedFormat }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioImportError.decoderUnavailable("start: \(reader.error?.localizedDescription ?? "unknown")")
        }
        defer { reader.cancelReading() }

        // Loading is idempotent in the core, and doing it here is what lets a
        // dropped file work before the user has ever dictated.
        do { try Core.loadASR() } catch let error as CoreError {
            throw Self.engineError(error, phase: "load")
        }
        do { try Core.startASR() } catch let error as CoreError {
            throw Self.engineError(error, phase: "start")
        }
        // Set only after the start succeeded: a session this call did not open
        // belongs to someone else, and stopping it would kill their recording.
        var sessionOwned = true
        // Any exit that is not the normal finish must end the session, or the
        // next recording is refused with "session already active".
        defer { if sessionOwned { _ = try? Core.stopASR() } }

        let resampler = AudioResampler(target: target)
        let chunkFrames = Int(Self.chunkSeconds * Self.targetRate)
        let totalFrames = max(chunkFrames, Int(seconds * Self.targetRate))
        var pending: [Float] = []
        pending.reserveCapacity(chunkFrames + 4_096)
        var segments: [TranscriptSegment] = []
        var decoded = 0
        var rejected = 0
        var reported = -1.0

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled { throw AudioImportError.cancelled }
            guard let floats = resampler.samples(from: sample), !floats.isEmpty else {
                rejected += 1
                continue
            }
            pending.append(contentsOf: floats)
            decoded += floats.count
            if pending.count >= chunkFrames {
                try submit(pending)
                drain(into: &segments)
                pending.removeAll(keepingCapacity: true)
            }
            let fraction = min(0.99, Double(decoded) / Double(totalFrames))
            if fraction - reported >= 0.01 {
                reported = fraction
                emit(fraction, onProgress)
                emit("辨識中…\(Int(fraction * 100))%", onStatus)
            }
        }

        if reader.status == .failed {
            throw AudioImportError.decoderUnavailable(reader.error?.localizedDescription ?? "reader failed")
        }
        guard decoded > 0 else {
            throw rejected == 0 ? AudioImportError.emptyAudio : AudioImportError.unsupportedFormat
        }
        if !pending.isEmpty {
            try submit(pending)
            drain(into: &segments)
            pending.removeAll(keepingCapacity: true)
        }

        emit("整理逐字稿…", onStatus)
        let stopText: String
        do { stopText = try Core.stopASR(); sessionOwned = false }
        catch let error as CoreError { throw Self.engineError(error, phase: "stop") }
        // `ASR_Stop` decodes the final utterance itself, so one more drain is
        // what puts the closing sentence in — the same tail the live path reads.
        drain(into: &segments)

        let joined = TranscriptDocument.join(segments.map(\.text))
        let text = joined.isEmpty ? stopText.trimmingCharacters(in: .whitespacesAndNewlines) : joined
        return AudioImportResult(text: text, duration: Double(decoded) / Self.targetRate, segments: segments)
    }

    // MARK: - Engine plumbing

    private func submit(_ samples: [Float]) throws {
        do { try Core.submit(samples, speaker: .me) }
        catch let error as CoreError { throw Self.engineError(error, phase: "submit") }
    }

    /// `takeSegments` is what makes the engine decode what was submitted, and
    /// per-chunk draining is also what keeps it far below its 20-minute cap.
    private func drain(into segments: inout [TranscriptSegment]) {
        do { segments.append(contentsOf: try Core.takeSegments()) }
        catch {
            // Costs text, not the import: the next drain returns everything
            // still undelivered.
            ModelInstaller.log("audio import: takeSegments failed — \(error)")
        }
    }

    /// 2 is "model not loaded", 6 is "invalid state". What 6 means depends on
    /// the phase: at start a live recording holds the session (do not retry into
    /// it), during submit or stop the session was lost under us.
    private static func engineError(_ error: CoreError, phase: String) -> AudioImportError {
        switch error {
        case let .status(code, message):
            switch (code, phase) {
            case (2, _), (6, "load"): return .modelsNotReady
            case (6, "start"): return .engineBusy
            default: return .engine("\(phase): \(message)")
            }
        }
    }

    // MARK: - Delivery

    private func finish(_ result: Result<AudioImportResult, AudioImportError>,
                        _ completion: @escaping (Result<AudioImportResult, AudioImportError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private func emit(_ value: Double, _ handler: @escaping (Double) -> Void) {
        let clamped = max(0, min(1, value))
        DispatchQueue.main.async { handler(clamped) }
    }

    private func emit(_ text: String, _ handler: @escaping (String) -> Void) {
        DispatchQueue.main.async { handler(text) }
    }

    // MARK: - Cancellation

    private func setCancelled(_ value: Bool) {
        stateLock.lock()
        cancelledFlag = value
        stateLock.unlock()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelledFlag
    }

    /// Sleeps in slices so a cancel during backoff is felt within a tick instead
    /// of after the whole delay. False means cancelled.
    private func sleepCancellable(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isCancelled
    }

    private static func claimEngine() -> Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        if importing { return false }
        importing = true
        return true
    }

    private static func releaseEngine() {
        busyLock.lock()
        importing = false
        busyLock.unlock()
    }
}

// MARK: - Decoding one sample buffer

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
    /// sample rate is not 16 kHz. Both AVFoundation initializers refuse more than
    /// two channels without a channel layout, so a surround file comes back nil
    /// here and is reported as unsupported rather than decoded with the wrong
    /// layout.
    private static func format(of sample: CMSampleBuffer) -> AVAudioFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        var copy = asbd
        return AVAudioFormat(streamDescription: &copy)
    }

    /// The reader was asked for interleaved float, so one AudioBuffer holds
    /// every channel and this is a single memcpy.
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

// MARK: - Dropping a file onto a view

private var audioDropCatcherKey: UInt8 = 0

extension NSView {
    /// One line to accept a dropped audio file:
    ///
    ///     transcriptPane.acceptAudioFileDrops { importer.importFile(at: $0, …) }
    ///
    /// NSView already conforms to `NSDraggingDestination`, but its handlers are
    /// open methods, which an extension cannot supply. So this puts a child view
    /// behind the others to do the accepting. Behind, not on top: buttons and
    /// text views keep their clicks, and a drop anywhere the host shows through
    /// still lands.
    func acceptAudioFileDrops(onDrop: @escaping (URL) -> Void) {
        if let previous = objc_getAssociatedObject(self, &audioDropCatcherKey) as? AudioDropCatcher {
            previous.removeFromSuperview()
        }
        let catcher = AudioDropCatcher(onDrop: onDrop)
        objc_setAssociatedObject(self, &audioDropCatcherKey, catcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        catcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(catcher, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            catcher.topAnchor.constraint(equalTo: topAnchor),
            catcher.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// The view that actually receives the drag. One closure, no global state, so
/// two windows cannot confuse each other's drops.
private final class AudioDropCatcher: NSView {
    private var onDrop: ((URL) -> Void)?

    init(onDrop: @escaping (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }

    /// Repeated while the pointer moves, and what keeps showing `.copy` — left
    /// to NSView's default the cursor can fall back to "no drop" after entry.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    /// Only real files: a dragged image or a scrap of text carries no file URL
    /// and is refused here rather than surfacing later as an import error.
    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }
}
