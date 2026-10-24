import AVFoundation
import CoreAudio

/// Captures what the Mac is *playing* -- the other people on a call -- so a
/// meeting transcript covers both sides of the conversation.
///
/// Uses a Core Audio process tap (macOS 14.2+) rather than ScreenCaptureKit.
/// That matters for permissions: a tap asks only for "System Audio Recording",
/// which is audio-only, while ScreenCaptureKit would ask for screen recording.
/// The audio is never muted: the user still has to hear the meeting.
///
/// Note on speakers: with the Mac on loudspeakers the microphone also hears the
/// far end, so a phrase can appear twice. Headphones avoid it entirely.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case unsupported
        case create(OSStatus)
        case noOutputDevice(OSStatus)
        case aggregate(OSStatus)
        case format
        case ioProc(OSStatus)
        case start(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "這個 macOS 版本不支援系統音訊擷取（需要 macOS 14.2 以上）"
            case let .create(status):
                return "無法錄製系統音訊（錯誤碼 \(status)）。請到「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」，允許 Offline Voice Assistant 錄製系統音訊。"
            case let .noOutputDevice(status):
                return "找不到預設輸出裝置（錯誤碼 \(status)）"
            case let .aggregate(status):
                return "建立系統音訊裝置失敗（錯誤碼 \(status)）"
            case .format:
                return "讀不到系統音訊的格式"
            case let .ioProc(status):
                return "建立系統音訊讀取失敗（錯誤碼 \(status)）"
            case let .start(status):
                return "啟動系統音訊擷取失敗（錯誤碼 \(status)）"
            }
        }
    }

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private let onSamples: ([Float]) -> Void
    private let onLevel: ((Float) -> Void)?
    /// The IOProc fires on a realtime-ish audio thread; do the conversion there
    /// and hand finished 16 kHz samples to the caller's own queue.
    private let ioQueue = DispatchQueue(label: "ovc.systemaudio")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(onSamples: @escaping ([Float]) -> Void, onLevel: ((Float) -> Void)? = nil) {
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupported }

        // A global tap is "everything the Mac plays"; this app plays no audio, so
        // there is nothing of our own to exclude.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Offline Voice Assistant"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.create(tapStatus)
        }
        tapID = tap

        // A tap cannot be read directly: it has to be published inside an
        // aggregate device, which then behaves like any other input device.
        //
        // Everything between creating the tap and starting the IOProc can
        // still fail, and a tap that is created but never destroyed keeps the
        // system recording with the orange microphone light on. So every exit
        // from here tears the tap down again.
        let outputUID: String
        do {
            outputUID = try Self.defaultOutputUID()
        } catch {
            destroyTap()
            throw error
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Offline Voice Assistant Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw TapError.aggregate(aggregateStatus)
        }
        self.aggregateID = aggregateID

        guard let format = Self.streamFormat(of: aggregateID) else {
            stop()
            throw TapError.format
        }
        inputFormat = format
        converter = AVAudioConverter(from: format, to: target)

        var proc: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue, block)
        guard procStatus == noErr, let proc else {
            stop()
            throw TapError.ioProc(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            stop()
            throw TapError.start(startStatus)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let proc = ioProcID {
                _ = AudioDeviceStop(aggregateID, proc)
                _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        destroyTap()
        converter = nil
        inputFormat = nil
    }

    /// Destroy just the process tap. Split out of `stop()` so the failure paths
    /// inside `start()` can release the tap without touching the aggregate
    /// device, which does not exist yet at that point.
    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        if #available(macOS 14.2, *) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        // Safety net: an owner that drops the tap without calling `stop()`
        // must not leave the system recording.
        stop()
    }

    // MARK: - Audio

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = inputFormat, let converter = converter else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard abl.count > 0, let pcm = Self.pcmBuffer(from: abl, format: format) else { return }

        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        onLevel?(AudioCapture.level(of: samples))
        onSamples(samples)
    }

    /// Copies an AudioBufferList into an AVAudioPCMBuffer, handling both the
    /// interleaved and non-interleaved layouts the tap may present.
    private static func pcmBuffer(from abl: UnsafeMutableAudioBufferListPointer,
                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frames = AVAudioFrameCount(abl[0].mDataByteSize / bytesPerFrame)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        if format.isInterleaved {
            guard let source = abl[0].mData,
                  let destination = pcm.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
            memcpy(destination, source, Int(abl[0].mDataByteSize))
        } else {
            guard let channels = pcm.floatChannelData else { return nil }
            for index in 0..<min(abl.count, Int(format.channelCount)) {
                guard let source = abl[index].mData else { return nil }
                memcpy(channels[index], source, Int(abl[index].mDataByteSize))
            }
        }
        return pcm
    }

    // MARK: - Core Audio lookups

    private static func defaultOutputUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &deviceAddress, 0, nil, &deviceSize, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.noOutputDevice(status)
        }

        // AudioObjectGetPropertyData hands back a +1 CFString for this property,
        // so take ownership rather than passing a CFString variable by address.
        var uid: Unmanaged<CFString>?
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        guard status == noErr, let value = uid else { throw TapError.noOutputDevice(status) }
        return value.takeRetainedValue() as String
    }

    private static func streamFormat(of device: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
