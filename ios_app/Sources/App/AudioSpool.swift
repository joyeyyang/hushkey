import AVFoundation
import Foundation

/// The dictation, on disk, while it is still being made.
///
/// A recording that lives only in memory is lost the moment iOS reclaims the app:
/// it does that without warning when memory is tight, and this app is about to be
/// backgrounded -- which is exactly when a phone reclaims things. Every buffer is
/// therefore written straight to a file in the App Group as it arrives: 16 kHz
/// mono float32, 3.8 MB for a full 60-second dictation. The file is the safety
/// net, not the data path; the recogniser is fed the same samples in memory.
///
/// The file is deleted only once the transcript has been published, so a crash
/// between the two costs a few seconds of repeated work rather than the sentence.
final class AudioSpool {
    static let sampleRate: Double = 16_000

    /// `<group>/spool/` -- next to the models, so both processes see the same
    /// directory and neither needs its own cleanup.
    static var directory: URL {
        SharedStore.container.appendingPathComponent("spool", isDirectory: true)
    }

    let url: URL
    private var file: AVAudioFile?
    private let writeFormat: AVAudioFormat
    private(set) var frames: AVAudioFramePosition = 0

    init() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        url = Self.directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        // The file is a WAV, but the buffers handed to `write(from:)` are the same
        // non-interleaved float32 the recogniser takes, so no conversion happens
        // on the way in or out.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
            channels: 1, interleaved: false
        ) else {
            throw CoreError.failed(-1, "無法建立錄音格式")
        }
        writeFormat = format
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    /// Seconds of audio on disk so far.
    var duration: Double { Double(frames) / Self.sampleRate }

    /// Called from the microphone's audio thread. A write that fails is logged and
    /// dropped: the recogniser still has the samples, and refusing the whole
    /// dictation over a full disk would be the worse outcome.
    func append(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: writeFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }

        do {
            try file.write(from: buffer)
            frames += AVAudioFramePosition(samples.count)
        } catch {
            Diagnostics.log.error("spool write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Flushes and closes. The file stays; `discard()` is what removes it.
    func close() {
        file = nil
    }

    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: leftovers

    /// Spools from a run that never finished -- the process died mid-sentence.
    /// Oldest first, and only ones that had time to receive audio.
    static func orphans(olderThan age: TimeInterval = 3) -> [URL] {
        dated()
            .filter { Date().timeIntervalSince($0.1) > age && Date().timeIntervalSince($0.1) < 600 }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Keeps the directory from growing without bound on a phone that dictates a
    /// lot and never finishes a launch.
    static func prune(keeping limit: Int = 6) {
        let files = dated().sorted { $0.1 > $1.1 }
        for (url, _) in files.dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func dated() -> [(URL, Date)] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".wav") }.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return (url, modified)
        }
    }
}
