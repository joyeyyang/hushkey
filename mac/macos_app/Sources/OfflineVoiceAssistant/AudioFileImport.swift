import AppKit
import VoiceInputKit

/// Transcribes an audio file through the kit.
///
/// The decoding, the resampling and the chunked feed are the kit's
/// (`VoiceInputEngine.transcribe(fileAt:)`) — the same code the microphone path
/// and the command-line tool run, so an imported file cannot drift from a
/// recording. What this class adds is the app's own part: the retry with a
/// backoff, the cancellation, the busy guard that keeps two imports from
/// fighting over the engine's single session, and the Chinese messages the
/// window shows.
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

    private static let maxAttempts = 3
    /// Delay before attempt 2, then before attempt 3.
    private static let backoff: [TimeInterval] = [0.5, 1.0, 2.0]

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
                    engine: VoiceInputEngine,
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
            self.run(url: url, engine: engine, onProgress: onProgress, onStatus: onStatus, completion: completion)
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
                     engine: VoiceInputEngine,
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
                let result = try importOnce(url: url, engine: engine, onProgress: onProgress, onStatus: onStatus)
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

    /// The decode itself, which is the kit's.
    ///
    /// The kit owns the ASR session for the length of the call and hands back
    /// the raw text, the segments and the decoded duration; the app maps them
    /// onto its own segment type and keeps the Chinese wording for the window.
    private func importOnce(url: URL,
                            engine: VoiceInputEngine,
                            onProgress: @escaping (Double) -> Void,
                            onStatus: @escaping (String) -> Void) throws -> AudioImportResult {
        emit("讀取音訊…", onStatus)
        let result: VoiceInputResult
        do {
            result = try engine.transcribe(fileAt: url) { fraction, status in
                self.emit(fraction, onProgress)
                self.emit(status, onStatus)
            }
        } catch {
            throw Self.map(error)
        }
        if isCancelled { throw AudioImportError.cancelled }
        let segments = result.segments.map {
            TranscriptSegment(
                index: $0.index,
                speaker: $0.source == .systemAudio ? .other : .me,
                start: $0.start,
                end: $0.end,
                text: $0.text
            )
        }
        let joined = TranscriptDocument.join(segments.map(\.text))
        let text = joined.isEmpty ? result.raw : joined
        return AudioImportResult(text: text, duration: result.duration, segments: segments)
    }

    /// The kit's errors into the app's, so the window can say what went wrong in
    /// the user's language instead of the library's.
    private static func map(_ error: Error) -> AudioImportError {
        guard let error = error as? VoiceInputError else {
            return .engine("\(error)")
        }
        switch error {
        case let .core(code, message):
            // 2 is "model not loaded", 6 is "invalid state". What 6 means depends
            // on the phase: at start a live recording holds the session (do not
            // retry into it), during submit or stop the session was lost under us.
            return .engine("core \(code): \(message)")
        case let .fileUnreadable(name):
            return .fileUnreadable(name)
        case .unsupportedFormat:
            return .unsupportedFormat
        case .noAudioTrack:
            return .noAudioTrack
        case .emptyAudio:
            return .emptyAudio
        case let .decoderUnavailable(why):
            return .decoderUnavailable(why)
        case .cancelled:
            return .cancelled
        case .microphoneDenied, .badConfig, .notStarted:
            return .engine(error.description)
        }
    }

    // MARK: - Engine plumbing

    private func emit(_ value: Double, _ handler: @escaping (Double) -> Void) {
        let clamped = max(0, min(1, value))
        DispatchQueue.main.async { handler(clamped) }
    }

    private func emit(_ text: String, _ handler: @escaping (String) -> Void) {
        DispatchQueue.main.async { handler(text) }
    }

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

    private func finish(_ result: Result<AudioImportResult, AudioImportError>,
                        _ completion: @escaping (Result<AudioImportResult, AudioImportError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Sleeps in short steps so a cancel is noticed within a fraction of a
    /// second instead of after the whole delay.
    private func sleepCancellable(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: 0.1)
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
