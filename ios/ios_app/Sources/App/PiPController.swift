import AVFoundation
import AVKit
import UIKit

/// The picture-in-picture window that makes dictation work without switching apps.
///
/// This is Mode 2. Mode 1 -- the default -- opens this app when the keyboard's
/// microphone is tapped, because the recording has to happen in the app: an
/// extension cannot reach the microphone at all (iOS refuses the permission
/// prompt inside an extension).
///
/// PiP is the way around that. A video-call PiP window keeps the app alive and
/// running in the background, so the app keeps the microphone, keeps recognising,
/// and the keyboard -- still on screen in whatever app the user was typing in --
/// shows the live caption and inserts the result. Nothing switches.
///
/// Three parts have to be true at once, and each fails silently on its own, so
/// each is checked here and reported in the log rather than assumed:
///
/// 1. The device supports call-style PiP (`isPictureInPictureSupported`).
/// 2. The app declares `UIBackgroundModes: audio` and holds an active audio
///    session; without them `startPictureInPicture` fails and the app is
///    suspended the moment it is backgrounded.
/// 3. A display layer keeps producing frames. A PiP window with no video is
///    closed by the system, so a 1 fps repaint of the current caption doubles as
///    the keep-alive.
@MainActor
final class PiPController: NSObject {
    static let shared = PiPController()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private var pip: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var layer: AVSampleBufferDisplayLayer?
    private var repaint: Timer?
    private var anchor: UIView?
    /// The last string drawn, so a 1 fps repaint does not rebuild an identical
    /// frame sixty times a minute.
    private var lastRendered: String?

    /// True while the system is actually showing the window. The keyboard asks
    /// this over the group (`PiPLive`) before trusting Mode 2: a mode that was
    /// chosen but is not running must not swallow the microphone tap.
    private(set) var isLive = false

    /// Starts PiP and keeps it up until `stop()`. `host` only anchors the window
    /// to this screen; it is never shown.
    func start(in host: UIView) {
        guard Self.isSupported else {
            Diagnostics.log.error("pip: unsupported on this device; Mode 2 unavailable")
            return
        }
        anchor = host
        // Already configured but not up (the window was closed, or the first
        // attempt failed): ask again instead of returning. Returning here meant
        // that after one failed start, choosing Mode 2 again did nothing for the
        // rest of the launch.
        if let existing = pip {
            if existing.isPictureInPictureActive {
                Diagnostics.log.notice("pip: already live")
            } else {
                Diagnostics.log.notice("pip: retrying a start that did not take")
                if existing.isPictureInPicturePossible {
                    existing.startPictureInPicture()
                } else {
                    Diagnostics.log.error("pip: still not possible; will not start until this app is backgrounded")
                }
                startRepaint()
                SharedStore.pipLive = isLive
            }
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.playAndRecord` with `.mixWithOthers`: the microphone is the point,
            // and mixing means the user's music or call keeps playing instead of
            // being interrupted by a dictation.
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Diagnostics.log.error("pip: audio session failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let vc = AVPictureInPictureVideoCallViewController()
        vc.preferredContentSize = CGSize(width: 480, height: 270)
        vc.view.backgroundColor = .black

        let display = AVSampleBufferDisplayLayer()
        display.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
        display.videoGravity = .resizeAspect
        vc.view.layer.addSublayer(display)
        self.callViewController = vc
        self.layer = display

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: vc
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // A call window can be dismissed by the user like any PiP window; keeping
        // it up is what the mode is for, so it is restarted rather than silently
        // turning Mode 2 into a microphone button that does nothing.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pip = controller

        // A first frame before asking, so the window has something to show.
        render(text: "準備好了")
        startRepaint()

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            Diagnostics.log.error("pip: not possible yet; it will start when this app is backgrounded")
        }
        Diagnostics.log.notice("pip: started")
    }

    func stop() {
        repaint?.invalidate()
        repaint = nil
        pip?.stopPictureInPicture()
        pip = nil
        layer?.flushAndRemoveImage()
        layer = nil
        callViewController = nil
        anchor = nil
        lastRendered = nil
        isLive = false
        SharedStore.pipLive = false
        Diagnostics.log.notice("pip: stopped")
    }

    /// Drops the controller after the system took the window away.
    ///
    /// Without this, `pip` stayed non-nil after a failure or a user-closed
    /// window, and every later `start()` early-returned on it: Mode 2 then looked
    /// selected and produced nothing, with no message to explain it.
    private func releaseWindow() {
        isLive = false
        SharedStore.pipLive = false
        repaint?.invalidate()
        repaint = nil
        pip = nil
        layer?.flushAndRemoveImage()
        layer = nil
        callViewController = nil
        lastRendered = nil
    }

    /// Attempts to start PiP when the app backgrounds, if configured but not yet live.
    /// Call this from the app's scenePhase handler on `.background`.
    func startOnBackgroundIfNeeded() {
        guard Self.isSupported else { return }
        guard SharedStore.mode == .pip else { return }
        guard let controller = pip else { return }
        guard !controller.isPictureInPictureActive else { return }
        // The controller was set up earlier (from RecorderTab), but PiP only
        // becomes possible when the app backgrounds. Try to start it now.
        if controller.isPictureInPicturePossible {
            Diagnostics.log.notice("pip: starting on background")
            controller.startPictureInPicture()
            startRepaint()
        } else {
            Diagnostics.log.error("pip: still not possible on background")
        }
    }

    /// Repaints the window with whatever the recogniser has heard so far, so the
    /// small window is the live caption rather than a static picture.
    fileprivate func refreshCaption() {
        // The heartbeat: the keyboard only trusts Mode 2 for a few seconds after
        // this stamp, so a process that dies without running its delegate does
        // not leave a "live" flag behind. One write a second, on the same timer
        // that already runs.
        if isLive { SharedStore.stampPiP() }
        let session = SharedStore.current()
        let text: String
        switch session.phase {
        case .recording:
            // The window is the live caption, so it shows the words rather than
            // the word "recording": it is already repainting once a second, and
            // three static characters waste the only place the user can see the
            // recogniser working while staying in the other app.
            text = session.partial.isEmpty ? "錄音中…" : String(session.partial.suffix(60))
        case .transcribing: text = "辨識中…"
        case .refining: text = "整理中…"
        case .done, .failed, .idle:
            let heard = session.text ?? ""
            text = heard.isEmpty ? "準備好了" : String(heard.suffix(60))
        }
        guard text != lastRendered else { return }
        lastRendered = text
        render(text: text)
    }

    private func startRepaint() {
        repaint?.invalidate()
        repaint = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCaption() }
        }
    }

    // MARK: frames

    private func render(text: String) {
        guard let layer, let buffer = frame(text: text) else { return }
        if layer.requiresFlushToResumeDecoding { layer.flush() }
        layer.enqueue(buffer)
    }

    /// One frame of black with the caption in the middle.
    private func frame(text: String) -> CMSampleBuffer? {
        let width = 480, height = 270
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: UIColor.white,
            .paragraphStyle: style,
        ]
        let rect = CGRect(x: 24, y: 0, width: width - 48, height: height)
        let drawn = NSAttributedString(string: text, attributes: attributes)
        UIGraphicsPushContext(context)
        drawn.draw(in: rect)
        UIGraphicsPopContext()

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            isLive = true
            SharedStore.pipLive = true
            Diagnostics.log.notice("pip: window is live")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated {
            releaseWindow()
            Diagnostics.log.notice("pip: window closed")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated {
            releaseWindow()
            // The usual causes, and the difference matters to whoever is reading
            // the log: no background mode, no audio session, or the simulator.
            Diagnostics.log.error("pip: failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
