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

    init() {
        // The keyboard's pause / resume buttons. Registered here rather than in a
        // view: the recording outlives every screen (that is the whole point of
        // Mode 1 and Mode 2), and a subscription owned by a view would stop
        // working exactly when the app is in the background with a microphone
        // open -- the only situation the buttons exist for.
        SharedStore.observePauseRequest { [weak self] paused in
            guard let self else { return }
            if paused { self.pause() } else { self.resume() }
        }
        // A stale `true` from a process the system killed would leave the keyboard
        // showing ▶ while nothing is listening.
        SharedStore.isPaused = false
    }

    @Published private(set) var phase: SharedStore.Phase = .idle
    /// Settled words, accumulated as the recogniser closes utterances.
    @Published private(set) var transcript = ""
    /// The utterance still open, shown while it is being spoken.
    @Published private(set) var live = ""
    /// A failure worth showing on the app's own screen.
    @Published private(set) var error: String?
    /// Whether the microphone is held but not listening.
    ///
    /// Distinct from "not recording": the sentence is still open, the spool is
    /// still being written to once it resumes, and nothing has been decoded. A
    /// phone dictation is interrupted constantly, and the Mac's pause is the right
    /// answer to that -- the alternative is publishing half a sentence or throwing
    /// the first half away.
    @Published private(set) var isPaused = false

    /// What the user should read right now, in one string.
    var display: String { transcript + live }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .recording || phase == .transcribing || phase == .refining }
    /// Whether a recovery of last launch's sentence is holding the pipeline.
    ///
    /// Read-only view of `recovering` for the outside: while it is true a microphone
    /// tap cannot start, and that is the difference between "the button is broken"
    /// and "the button is waiting for last launch's sentence".
    var isRecovering: Bool { recovering }

    private let work = DispatchQueue(label: "ovc.dictation", qos: .userInitiated)

    private var mic: MicCapture?
    private var spool: AudioSpool?
    private var gate: SilenceGate?
    private var pollTimer: Timer?
    private var background: UIBackgroundTaskIdentifier = .invalid
    /// The transcript as heard, kept while the cleanup pass runs so a timeout can
    /// publish it instead of losing it.
    private var pendingRaw: String?
    /// Bounds the cleanup pass. A model that never returns would otherwise leave
    /// the keyboard on "整理中…" forever, and the sentence -- already decoded and
    /// sitting in `pendingRaw` -- would never be handed over.
    private var refineTimer: Timer?
    /// Bounds the decode, which had no deadline at all until a user hit it.
    ///
    /// The cleanup pass has had one since it was written; the decode never did, and
    /// that asymmetry is what left the recorder button dead: `isBusy` is true for
    /// `.transcribing`, `RecorderTab` disables the button for every busy phase
    /// except `.recording`, and a completion that never arrives leaves the phase
    /// there for the life of the process. The background-task expiry was not a
    /// backstop either -- with nothing decoded yet there was no text to publish, and
    /// that path did nothing at all.
    ///
    /// Renewed on progress, so a long file import is not cut off: this bounds
    /// SILENCE, not work.
    private var decodeTimer: Timer?
    /// Set when a decode had to be cut off. The recogniser call that was still
    /// running holds the core's own lock, so the next dictation has a good chance of
    /// queuing behind it -- better said out loud than watched.
    private var decodeTimedOut = false
    /// Bounds a launch recovery, independently of the decode. `recovering` gates
    /// `start()` (a microphone tap queues behind it), so it cannot be allowed to
    /// stay true because something inside the recovery never returned.
    private var recoveryTimer: Timer?
    /// A spool file inherited from a killed run. Removed once its words are
    /// published, so a second crash does not lose the sentence.
    private var orphanSource: URL?
    /// Whether that file is a `*.claimed` one.
    ///
    /// Kept as state rather than read off the extension: `recoverOrphan` calls
    /// `runInjected` with a plain `.wav` when `claim` fails, and that file is just
    /// as much the only copy of the sentence. Asking the extension made a claim
    /// failure look like "not ours" and let `fail()` delete it.
    private var orphanWasClaimed = false
    /// Whether `runInjected` got as far as reading the audio. A failure after
    /// this point is about the audio, not about the engine, and that distinction
    /// decides whether a claimed spool is retried or dropped.
    private var injectedAudioReady = false
    /// Set when the audio came back from disk after the system killed the app.
    /// That sentence has already cost the user one attempt, so it is published as
    /// heard rather than risking the slow path again.
    private var skipRefine = false
    /// Which dictation the pending work belongs to.
    ///
    /// Every completion -- decode, cleanup pass, the background deadline, the
    /// live-word poll -- checks this before touching state. Without it, "clear"
    /// followed by a decode that was already in flight still published the
    /// previous sentence to the keyboard, and a second dictation's cleanup pass
    /// could land in the middle of the first one's.
    private var generation = 0
    /// The generation whose result has already been handed over. One dictation
    /// publishes once, whichever deadline gets there first.
    private var publishedGeneration = -1
    /// The recogniser is loaded once per launch. `onAppear` can run twice, and a
    /// second `Core_Initialize` would reload a 100 MB model for nothing.
    private var prewarmed = false
    /// True while `recoverOrphan` is running the previous launch's sentence.
    private var recovering = false
    /// One recovery per launch. `onAppear` can run twice, and older spools are now
    /// kept on purpose, so without this the same launch could deliver two stale
    /// sentences in a row.
    private var didRecoverOrphan = false
    /// A microphone tap that arrived during recovery. Last launch's sentence is
    /// the only copy the user has of what they said, so the tap waits for it
    /// rather than either dropping the sentence or ignoring the tap.
    private var startAfterRecovery = false
    /// When the sentence started being spoken, for the history entry's duration.
    /// Not when the microphone opened: the two differ by the permission prompt on
    /// a first run, and a duration that includes a permission dialog is a lie.
    private var startedAt: Date?
    /// The `tmp` copy of a file the user imported. Deleted with the dictation, so
    /// repeating the import does not accumulate copies of the same recording.
    private var importedSource: URL?

    @discardableResult
    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    // MARK: start

    /// Loads the recogniser before the first dictation.
    ///
    /// The keyboard's microphone tap opens the app and expects it to be recording
    /// on the first frame. Waiting for a 100 MB model to map would show a second of
    /// "待機" first, so the load happens while the user is still in the app they
    /// were typing in.
    func prewarm() {
        guard SharedStore.hasModels, !prewarmed else { return }
        prewarmed = true
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                Diagnostics.log.notice("recogniser ready")
            } catch {
                DispatchQueue.main.async { self.prewarmed = false }
                Diagnostics.log.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Mode 2 keeps the audio session up. Deactivating it closes the PiP window
    /// the app is living inside, and Mode 2 then stops working without a word:
    /// the setting still says "no app switch" while every microphone tap opens
    /// the app. A failed dictation is not a reason to end the session -- the
    /// window is a separate concern from the microphone.
    private var keepsAudioSession: Bool {
        SharedStore.mode == .pip || PiPController.shared.isLive
    }

    /// Begins a dictation from the microphone. Safe to call when one is already
    /// running: the keyboard reopens the app on every microphone tap.
    func start() {
        guard !isBusy else {
            // A recovery of last launch's sentence is holding the pipeline. The
            // tap outranks it, but dropping the recovery would throw away the
            // only copy of something the user already said once, so it runs as
            // soon as the queue frees (see `finishRecovery`).
            if recovering { startAfterRecovery = true }
            // Never silent. A tap that does nothing is indistinguishable from a
            // broken button -- which is exactly how this was reported: "the
            // microphone will not press". The pipeline is fine; it is busy, and it
            // says so.
            error = decodeTimedOut
                ? "上一次辨識沒有回應。如果這次也沒有開始錄音，請把 App 關掉再開一次。"
                : (recovering
                    ? "正在補回上一次的錄音，完成後就會開始。"
                    : "上一句還在處理，完成後就會開始。")
            return
        }
        let g = nextGeneration()
        reset()
        phase = .recording
        startedAt = Date()
        SharedStore.setPhase(.recording, detail: "錄音中…")
        // The last dictation's live words are still on the shared key, and the
        // keyboard draws them the moment the phase says "recording".
        SharedStore.setPartial("")

        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                guard granted else {
                    self.fail("需要麥克風權限。請到 設定 › Hushkey 開啟「麥克風」。")
                    return
                }
                self.openMicrophone(g: g)
            }
        }
    }

    private func openMicrophone(g: Int) {
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription, g: g) }
                return
            }
            DispatchQueue.main.async { self.attach(g: g) }
        }
    }

    private func attach(g: Int) {
        guard phase == .recording, g == generation else { return }
        do {
            // Resuming re-attaches a microphone to a sentence that already has a
            // spool. A fresh one would split the recording in two, and the second
            // file would be the only thing recovery could find.
            let spool = try self.spool ?? AudioSpool()
            let mic = MicCapture()
            let gate = SilenceGate()
            let spooled = spool

            gate.onFire = { [weak self] reason in
                DispatchQueue.main.async { self?.stop(reason: reason) }
            }
            mic.onSamples = { samples in
                spooled.append(samples)
                Core.submit(samples)
                gate.consume(samples)
            }

            do {
                try mic.start(keepAlive: keepsAudioSession)
            } catch {
                // The spool file exists as soon as it is created. Dropping the
                // reference would leave it for `recoverOrphan` to find on every
                // later launch, decode to nothing, and fail on again, for ever.
                spool.discard()
                throw error
            }
            self.spool = spool
            self.mic = mic
            self.gate = gate
            self.isPaused = false
            SharedStore.isPaused = false
            startPolling(g: g)
            Diagnostics.log.notice("dictation started")
        } catch {
            fail(error.localizedDescription, g: g)
        }
    }

    // MARK: pause

    /// Stops listening without ending the sentence.
    ///
    /// The ASR session stays open (`Core.stop` is what finishes it) and the spool
    /// stays on disk, so resuming appends to the same recording rather than
    /// starting a second one. The silence gate is dropped with the microphone: it
    /// fires on *absence* of audio, so leaving it armed while paused would auto-stop
    /// the dictation a second later and publish the half the user was pausing to
    /// protect.
    func pause() {
        guard phase == .recording, !isPaused else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        // The open utterance is a preview, not committed words: keeping it on
        // screen while paused is honest (it was said), and `resume` picks the tail
        // up from the recogniser.
        live = ""
        isPaused = true
        SharedStore.isPaused = true
        mic?.onSamples = nil
        mic?.stop(keepAlive: keepsAudioSession)
        mic = nil
        gate = nil
        SharedStore.setPhase(.recording, detail: "已暫停")
        Diagnostics.log.notice("dictation paused")
    }

    /// Starts listening again on the sentence that was paused.
    func resume() {
        guard phase == .recording, isPaused else { return }
        isPaused = false
        SharedStore.isPaused = false
        SharedStore.setPhase(.recording, detail: "錄音中…")
        attach(g: generation)
        Diagnostics.log.notice("dictation resumed")
    }

    // MARK: stop

    /// Ends the dictation and decodes what is left. `reason` is shown to the user
    /// ("靜音" when they simply stopped talking).
    func stop(reason: String = "") {
        guard phase == .recording else { return }
        pollTimer?.invalidate()
        pollTimer = nil

        mic?.onSamples = nil
        mic?.stop(keepAlive: keepsAudioSession)
        mic = nil
        gate = nil

        decode(accumulated: transcript, reason: reason, g: generation)
    }

    private func decode(accumulated: String, reason: String, g: Int) {
        phase = .transcribing
        SharedStore.setPhase(.transcribing, detail: "辨識中…")
        startDecodeDeadline(g: g)
        // The user is about to leave for the app they were typing in. This keeps
        // the process alive for the seconds the decode needs.
        beginBackground(g: g)

        work.async {
            // `-OVC_HANG_DECODE`: the fault, injected. This is what a `Core.stop()`
            // that never returns looks like from here, and it is the only way to
            // produce the stuck state on purpose -- the recogniser either returns or
            // the process dies. Never reached without the launch flag.
            if Diagnostics.hangsDecode {
                Diagnostics.log.error("decode hung on purpose (-OVC_HANG_DECODE)")
                return
            }
            let final: String
            do {
                final = try Core.stop()
            } catch {
                // No longer swallowed by `try?`. A stop that throws means this
                // dictation's tail is missing, and the log is where that is
                // recorded; the words already closed still go out.
                Diagnostics.log.error(
                    "Core.stop failed: \(error.localizedDescription, privacy: .public)"
                )
                final = ""
            }
            let out = Self.merge(accumulated, final)
            DispatchQueue.main.async {
                self.complete(out, reason: reason, g: g)
            }
        }
    }

    // MARK: the decode's deadline

    /// How long the decode may stay silent. The cleanup pass uses the same number
    /// for the same reason: iOS gives a backgrounded app about thirty seconds, and a
    /// deadline inside that window means this side decides what happens rather than
    /// racing a kill it cannot log.
    private static let decodeSilence: TimeInterval = 25

    private func startDecodeDeadline(g: Int) {
        decodeTimer?.invalidate()
        decodeTimer = Timer.scheduledTimer(withTimeInterval: Self.decodeSilence, repeats: false) {
            [weak self] _ in
            self?.decodeRanOutOfTime(g: g)
        }
    }

    /// Called on progress: a decode that is still producing words is working, and a
    /// long import must not be cut off for taking a long time.
    private func renewDecodeDeadline(g: Int) {
        guard decodeTimer != nil, g == generation, phase == .transcribing else { return }
        startDecodeDeadline(g: g)
    }

    private func cancelDecodeDeadline() {
        decodeTimer?.invalidate()
        decodeTimer = nil
    }

    /// The decode ran out of time, or the system took the background time away.
    ///
    /// One answer to both, because they are the same situation: nothing more is
    /// coming. What was heard is handed over -- a rough sentence is still the user's
    /// sentence -- and when nothing was heard the dictation fails, which is the part
    /// that guarantees the phase leaves `.transcribing` and the microphone comes
    /// back.
    private func decodeRanOutOfTime(g: Int) {
        guard g == generation, phase == .transcribing else { return }
        cancelDecodeDeadline()
        decodeTimedOut = true
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty {
            Diagnostics.log.error("decode overran its deadline with nothing decoded")
            fail("辨識逾時，沒有拿到文字。再說一次，靠近一點。", g: g)
        } else {
            Diagnostics.log.error("decode overran its deadline; publishing as heard")
            publish(heard, detail: "已辨識 · 逾時", g: g)
        }
    }

    // MARK: the recovery's deadline

    /// How long a launch recovery may hold the pipeline. Longer than the decode's,
    /// because it is measured across the whole run (load, read, feed, decode) rather
    /// than across one stage of it, and the sentence it is recovering is already
    /// late.
    private static let recoveryLimit: TimeInterval = 60

    private func startRecoveryDeadline() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: Self.recoveryLimit, repeats: false) {
            [weak self] _ in
            guard let self, self.recovering else { return }
            // `recovering` gates `start()`: while it is true a microphone tap only
            // queues. So it cannot be allowed to stay true because something inside
            // the recovery never returned -- the sentence is not coming back, and
            // the user's next tap should not pay for it.
            Diagnostics.log.error("recovery overran its deadline; releasing the pipeline")
            self.fail("上次的錄音來不及補回來，麥克風已經放開。", g: self.generation)
        }
    }

    private func cancelRecoveryDeadline() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func complete(_ raw: String, reason: String, g: Int) {
        guard g == generation else { return }
        // The decode came back, so whatever was slow is not slow now.
        decodeTimedOut = false
        cancelDecodeDeadline()
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            spool?.discard()
            spool = nil
            endBackground()
            fail("沒有聽到聲音。再說一次，靠近一點。", g: g)
            return
        }

        // Script first, before the model sees anything, and the model's answer is
        // guarded afterwards. Both live in `Refiner` -- the same chain, thresholds
        // and fallbacks the Mac runs, walked across rather than re-invented.
        let heard = Refiner.fallback(raw)
        transcript = heard
        live = ""

        guard SharedStore.refineEnabled, !skipRefine else {
            publish(heard, detail: reason.isEmpty ? "已辨識" : "已辨識 · \(reason)", g: g)
            return
        }

        // The cleanup pass, on the same background time the decode started. If it
        // does not finish, the transcript is published as heard rather than
        // dropped: a rough sentence is still the user's sentence.
        pendingRaw = heard
        phase = .refining
        SharedStore.setPhase(.refining, detail: "整理中…")
        startRefineDeadline(g: g)

        work.async {
            // One call, one chain: Script → refine → sanity guard → translate.
            // The guard is the part iOS never had, and its absence is why a small
            // model's answer to the *instructions* could be published verbatim.
            let result = Refiner.refine(
                raw: raw,
                polish: true,
                translateTarget: Preferences.translateTarget
            )
            let served = Core.lastModelName()
            DispatchQueue.main.async {
                guard g == self.generation, self.phase == .refining else { return }
                // Which model answered is a fact the core reports, not something to
                // infer from how long the pass took.
                if !served.isEmpty, served != LLMPolicy.requestedName {
                    LLMPolicy.recordIfDowngraded(
                        served: served,
                        reason: "整理時 \(LLMPolicy.requestedName) 無法執行，改用 \(served)"
                    )
                } else if !served.isEmpty {
                    // Proof that this phone *can* run the model it was asked for.
                    // The background deadline reads it before blaming the model.
                    LLMPolicy.notePreferredServed()
                }
                var detail = reason.isEmpty ? "已整理" : "已整理 · \(reason)"
                if let note = result.note { detail += " · \(note)" }
                self.publish(result.text, detail: detail, g: g, model: served)
            }
        }
    }

    /// Hands over the unedited transcript if the cleanup pass overruns.
    ///
    /// Below the ~30 seconds iOS allows a backgrounded app, so the app decides
    /// what happens rather than racing the system's own deadline: a phone that is
    /// busy gives the user their words a few seconds early instead of losing the
    /// pass to a kill it cannot log.
    private func startRefineDeadline(g: Int) {
        refineTimer?.invalidate()
        refineTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, g == self.generation, self.phase == .refining,
                  let raw = self.pendingRaw
            else { return }
            Diagnostics.log.error("refine overran its deadline; publishing as heard")
            // Thirty seconds is already inside the window iOS gives a backgrounded
            // app, so this is the device saying the model is too slow -- for good,
            // not once. Recorded so the next launch starts on the smaller one
            // instead of losing the pass again.
            //
            // Unless the preferred model has never finished a pass here: the first
            // cleanup after an install also pays a ~18-second Metal library
            // compile, so an overrun *then* is the compile, not the model. A
            // downgrade recorded there would turn one slow first run into a
            // permanent model change -- the same mistake as before, one layer down.
            guard LLMPolicy.preferredHasSucceeded else {
                Diagnostics.log.notice("first pass after install overran; not recording a downgrade")
                self.publish(raw, detail: "已辨識 · 未整理", g: g)
                return
            }
            LLMPolicy.recordDowngrade(reason: "整理超過 25 秒，未在背景時間內完成")
            // The pass itself cannot be interrupted -- it is one blocking call
            // into llama.cpp -- so it keeps the work queue busy and the next
            // dictation waits behind it. The result is discarded by generation,
            // but the wait is real: logged, not hidden.
            Diagnostics.log.notice("the abandoned cleanup pass still occupies the work queue")
            self.publish(raw, detail: "已辨識 · 未整理", g: g)
        }
    }

    private func publish(_ text: String, detail: String, g: Int, model: String = "") {
        guard g == generation, publishedGeneration != g else { return }
        publishedGeneration = g
        pendingRaw = nil
        refineTimer?.invalidate()
        refineTimer = nil
        cancelDecodeDeadline()
        decodeTimedOut = false
        cancelRecoveryDeadline()
        endBackground()
        transcript = text
        live = ""
        phase = .done
        isPaused = false
        SharedStore.isPaused = false
        // The words are written first. Deleting the audio before the handoff wrote
        // anything means a failure in between (no App Group, a kill) leaves neither
        // the file nor the text -- the one ordering that can lose a sentence
        // outright, on a path whose whole point is not losing it.
        SharedStore.publish(text, detail: detail)
        // And kept in history for the same reason the Mac keeps one: the field the
        // text was typed into is not somewhere a phone user can go back to.
        History.add(
            text: text,
            detail: detail,
            model: model.isEmpty ? Core.lastModelName() : model,
            seconds: startedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
        startedAt = nil
        spool?.discard()
        spool = nil
        if let orphanSource {
            try? FileManager.default.removeItem(at: orphanSource)
            self.orphanSource = nil
        }
        removeImportedSource()
        isPaused = false
        Diagnostics.log.notice("dictation done: \(text.count, privacy: .public) chars")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finishRecovery()
    }

    /// Ends a `recoverOrphan` run, and starts the dictation a microphone tap
    /// asked for while it was running.
    private func finishRecovery() {
        recovering = false
        cancelRecoveryDeadline()
        guard startAfterRecovery else { return }
        startAfterRecovery = false
        // Last launch's sentence is on its way to the keyboard, so the
        // microphone is free for the sentence the user is saying now.
        start()
    }

    /// Replaces the sentence on screen with a version the user asked for with a
    /// 修改提示詞.
    ///
    /// Deliberately NOT published to the keyboard. The keyboard has already
    /// inserted the original at the cursor, and `SharedStore.publish` hands it a
    /// NEW sequence to insert -- so a second publish would type the corrected
    /// sentence *after* the uncorrected one. The result stays on this page and
    /// the 複製 button carries it back; replacing text the keyboard no longer
    /// owns is a different feature, and one it cannot do from here.
    func replaceTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript = trimmed
        live = ""
        phase = .done
        error = nil
        History.add(text: trimmed, detail: "已修改", model: Core.lastModelName())
    }

    func clear() {
        let wasBusy = isBusy
        let wasRecording = phase == .recording
        // `stop()` hands the tail of the recording to the decode, which belongs
        // to this generation. Bumping after it, so that decode is discarded
        // instead of publishing the sentence the user just cleared.
        if wasBusy { stop() }
        // `stop()` only exists for a live microphone. A recovery (or an injected
        // run) is already transcribing, so it returns without closing the
        // recogniser session -- and Rust refuses the next `start` with "ASR
        // session already active", which shows up as a failed first tap after
        // every cancelled recovery. Queued on the same serial queue, so it lands
        // before any dictation the user starts next.
        if wasBusy, !wasRecording {
            work.async { _ = try? Core.stop() }
        }
        nextGeneration()
        reset()
        phase = .idle
        recovering = false
        startAfterRecovery = false
        SharedStore.clear()
    }

    private func reset() {
        transcript = ""
        live = ""
        error = nil
        pendingRaw = nil
        isPaused = false
        SharedStore.isPaused = false
        startedAt = nil
        refineTimer?.invalidate()
        refineTimer = nil
        cancelDecodeDeadline()
        cancelRecoveryDeadline()
        skipRefine = false
        injectedAudioReady = false
        orphanWasClaimed = false
        // The audio belongs to the dictation being replaced. Leaving it behind is
        // how a sentence the user explicitly cleared comes back on the next launch:
        // `recoverOrphan` cannot tell "the app was killed" from "the user said
        // never mind", so it decodes the file and types it.
        spool?.discard()
        spool = nil
        if let orphanSource {
            try? FileManager.default.removeItem(at: orphanSource)
            self.orphanSource = nil
        }
        // A background task that is never ended makes iOS kill the process when
        // its time expires, and leaves `background` non-invalid so the *next*
        // dictation gets no protection at all.
        endBackground()
        removeImportedSource()
    }

    private func fail(_ message: String, g: Int? = nil) {
        if let g, g != generation { return }
        pollTimer?.invalidate()
        pollTimer = nil
        let hadMicrophone = mic != nil
        mic?.onSamples = nil
        mic?.stop(keepAlive: keepsAudioSession)
        mic = nil
        gate = nil
        // `MicCapture.start` sets the category and activates the session *before*
        // it starts the engine. When the engine itself throws, `self.mic` was never
        // assigned, so nothing below deactivates what was already opened -- and the
        // next dictation inherits a session it did not ask for.
        if !hadMicrophone, !keepsAudioSession {
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        }
        spool?.discard()
        spool = nil
        if let orphanSource {
            // When the failure came before the audio was even read, it was the
            // engine refusing to start (bad models, a session the last run left
            // open) -- nothing to do with this file, so the sentence goes back into
            // the queue for the next launch instead of being thrown away with the
            // fault. A claimed file has to be renamed back to be picked up again; a
            // plain `.wav` is already in the queue, so it is simply left alone. That
            // second case matters: `claim` can fail, and then the file handed here
            // is a `.wav` -- deleting it would throw the sentence away for a rename
            // that never happened.
            if !injectedAudioReady {
                if orphanWasClaimed { AudioSpool.unclaim(orphanSource) }
            } else {
                // The audio was read, so this failure is about the audio: decoding
                // it again would fail the same way and block the older spools
                // behind it.
                try? FileManager.default.removeItem(at: orphanSource)
            }
            self.orphanSource = nil
            self.orphanWasClaimed = false
        }
        pendingRaw = nil
        refineTimer?.invalidate()
        refineTimer = nil
        cancelDecodeDeadline()
        cancelRecoveryDeadline()
        endBackground()
        phase = .failed
        error = message
        SharedStore.setPhase(.failed, detail: message)
        Diagnostics.log.error("dictation failed: \(message, privacy: .public)")
        // The recogniser session may have been opened and then abandoned -- the
        // microphone failed, or the user stopped before it attached. Rust refuses
        // a second `start` while a session is open, so without this the next
        // dictation fails the same way and only a relaunch clears it.
        work.async { _ = try? Core.stop() }
        finishRecovery()
    }

    // MARK: live words

    private func startPolling(g: Int) {
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
                    guard g == self.generation, self.phase == .recording else { return }
                    for segment in closed { self.transcript += segment.text }
                    self.live = open
                    SharedStore.setPartial(self.transcript + open)
                }
            }
        }
    }

    // MARK: background time

    private func beginBackground(g: Int) {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "ovc.decode") { [weak self] in
            // Out of time: publishing what is finished beats being killed with
            // nothing. In particular a sentence still waiting on the cleanup pass
            // goes out exactly as it was heard.
            DispatchQueue.main.async {
                guard let self else { return }
                // Hand the task back before anything else. An expired task that is
                // never ended is what iOS kills the app for, and leaving it open
                // would also block the next dictation from getting any background
                // time at all -- which is the one thing that path needs.
                self.endBackground()
                guard g == self.generation else { return }
                // One place decides what "out of time" means, and this is it: the
                // cleanup pass keeps its own wording (its text is already decoded,
                // only the polish is missing) and everything else goes through the
                // decode's handler. The old version of this block had a hole with no
                // handler at all -- out of background time with nothing decoded yet
                // matched neither branch, and the phase stayed `.transcribing` for
                // the life of the process, with the microphone button disabled.
                if self.phase == .refining {
                    let raw = self.pendingRaw ?? self.transcript
                    if raw.isEmpty {
                        self.fail("沒有聽到聲音。再說一次，靠近一點。", g: g)
                    } else {
                        self.publish(raw, detail: "已辨識 · 未整理", g: g)
                    }
                } else {
                    self.decodeRanOutOfTime(g: g)
                }
            }
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: files

    /// Transcribes a recording the user picked, through the same pipeline.
    ///
    /// The Mac's 匯入音檔 equivalent, and it is the same code on purpose: the file
    /// is read into samples, fed to the recogniser exactly as live audio is, and
    /// the cleanup pass runs on the result. Anything AVFoundation can open works,
    /// so a voice memo taken before this app existed is not a second-class input.
    ///
    /// The file is copied to `tmp` first. A security-scoped URL is only readable
    /// while the scope is open, and the read happens on the work queue after this
    /// returns -- so the copy is what makes the access lifetime correct rather than
    /// lucky.
    func transcribeFile(_ url: URL) {
        guard !isBusy else {
            fail("還在處理上一段，稍等再匯入。")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            fail("讀不到這個音檔：\(error.localizedDescription)")
            return
        }
        runInjected(url: copy, detail: "音檔", treatingAsFile: true)
        // Recorded *after* the call: `runInjected` resets first, and that reset
        // deletes the previous import — setting the field before it would delete the
        // copy this very call is about to read.
        importedSource = copy
    }

    private func removeImportedSource() {
        if let importedSource {
            try? FileManager.default.removeItem(at: importedSource)
            self.importedSource = nil
        }
    }

    // MARK: injected audio

    /// Runs the whole pipeline over a file instead of the microphone.
    ///
    /// The simulator has no usable microphone, and the pipeline is the part worth
    /// testing anyway: everything after the sample buffer is identical. Reached
    /// with `-OVC_AUDIO_FILE <path.wav>`, which is also how the regression check
    /// drives a known sentence end to end.
    func runInjected(url: URL, detail: String = "測試音", skipRefine: Bool = false,
                     treatingAsFile: Bool = false) {
        guard !isBusy else { return }
        let g = nextGeneration()
        reset()
        self.skipRefine = skipRefine
        // A recovery decodes last launch's sentence; it is not recording. Claiming
        // `.recording` would put 錄音中 on the keyboard while the microphone is
        // closed, so a user who taps at that moment talks into a dictation that
        // never started -- the failure the launch delay only narrows. An imported
        // file is the same situation for a different reason: nothing is being
        // spoken, so the screen says 辨識中 and the keyboard says the same.
        let announcing: SharedStore.Phase = (recovering || treatingAsFile) ? .transcribing : .recording
        phase = announcing
        SharedStore.setPhase(
            announcing,
            detail: treatingAsFile ? "辨識音檔…" : (recovering ? "補回上次的錄音…" : "錄音中…")
        )
        // Armed here, not only in `decode()`: everything between this line and the
        // recogniser -- loading the model, reading the file, feeding the samples --
        // can be where it stops, and the phase is already `.transcribing` while it
        // does. A launch recovery that hung in `Core.initialize` left the button
        // dead with no timer anywhere.
        if announcing == .transcribing { startDecodeDeadline(g: g) }
        // Set before anything can fail, not after the file has been read: this file
        // is the only copy of that sentence, and every exit (`publish`, `fail`,
        // `reset`) finds it through this property. Assigned late, an engine that
        // refused to start left a claimed file nobody would ever look at again, and
        // each launch consumed one more spool.
        if url.deletingLastPathComponent().standardizedFileURL
            == AudioSpool.directory.standardizedFileURL {
            orphanSource = url
            orphanWasClaimed = url.pathExtension == "claimed"
        }
        Diagnostics.log.notice("dictation injected: \(url.lastPathComponent, privacy: .public)")

        // Read once, before leaving the main actor: `clear()` can flip these while
        // the block below is still feeding audio, and a stale read is the difference
        // between "write a second spool" and "do not".
        let isRecovery = recovering
        work.async {
            do {
                try Core.initialize(models: SharedStore.modelsRoot)
                try Core.start()
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription, g: g) }
                return
            }

            let samples: [Float]
            do {
                samples = try Self.readMono16k(url)
            } catch {
                Self.discardIfUnreadable(url)
                let what = isRecovery ? "上次的錄音" : "測試音"
                DispatchQueue.main.async {
                    self.fail("讀不到\(what)：\(error.localizedDescription)", g: g)
                }
                return
            }
            guard !samples.isEmpty else {
                Self.removeSpool(url)
                let what = isRecovery ? "上次的錄音" : "測試音"
                DispatchQueue.main.async { self.fail("\(what)是空的", g: g) }
                return
            }
            DispatchQueue.main.async { self.injectedAudioReady = true }

            // Written through the same spool as live audio, so the disk path is
            // exercised too -- a bug there would otherwise only show on a phone.
            // A recovery does not need one: its audio is already the file it is
            // decoding, and a second copy of the same sentence becomes "the newest
            // orphan" the moment the process is killed mid-decode -- so the next
            // launch would decode a truncated copy and treat the complete file as
            // abandoned.
            let spool = isRecovery ? nil : try? AudioSpool()
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
                        guard g == self.generation, self.phase == announcing else { return }
                        self.live = open
                        SharedStore.setPartial(open)
                        // Progress, so the deadline moves: a ten-minute import takes
                        // a while to hand over, and time spent producing words is not
                        // time spent stuck.
                        self.renewDecodeDeadline(g: g)
                    }
                }
            }
            spool?.close()

            DispatchQueue.main.async {
                guard g == self.generation, self.phase == announcing else {
                    // Cleared or failed while the file was being fed: the spool
                    // was created here, so removing it is this side's job.
                    spool?.discard()
                    return
                }
                self.spool = spool
                self.decode(accumulated: "", reason: detail, g: g)
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
        // One recovery per launch. `onAppear` can run more than once, and now that
        // older spools are kept deliberately, a second pass would deliver a second
        // stale sentence in the same launch.
        guard !didRecoverOrphan else { return }
        didRecoverOrphan = true
        // Reported before pruning: `prune` deletes the oldest files first and the
        // claims are the oldest things that never go away, so pruning first would
        // silently remove the very files this line exists to mention.
        let abandoned = AudioSpool.abandonedClaims()
        if !abandoned.isEmpty {
            // A recovery that was itself killed, or one whose publish never came
            // back. Either way nothing will decode these. The wording stops short
            // of "not delivered": a claim is also left behind when the app died
            // between publishing and deleting it, and that sentence did arrive.
            Diagnostics.log.error(
                "recovery left \(abandoned.count) claimed spool(s); they will not be retried"
            )
        }
        AudioSpool.prune()
        let orphans = AudioSpool.orphans()
        guard let newest = orphans.last else { return }
        // The older spools are left alone. They used to be deleted here, but the
        // recovery writes another spool into this same directory -- so being killed
        // a second time made the half-fed copy the newest, and the next launch
        // would have deleted the complete original along with it. A spool is
        // 3.8 MB at most and `prune` bounds how many survive.
        if orphans.count > 1 {
            Diagnostics.log.notice(
                "recovering spool \(newest.lastPathComponent, privacy: .public); \(orphans.count - 1) older one(s) kept"
            )
        } else {
            Diagnostics.log.notice("recovering spool \(newest.lastPathComponent, privacy: .public)")
        }
        // Claimed before decoding, so this file cannot be recovered a second time
        // by a later launch -- the recovery writes its own spool, and "newest
        // orphan" would otherwise be the half-fed copy while the original came
        // back again and was typed twice. A failed claim leaves the file in the
        // candidate set, which is the old behaviour; the log says which happened.
        guard let claimed = AudioSpool.claim(newest) else {
            recovering = true
            startRecoveryDeadline()
            runInjected(url: newest, detail: "補回上次的錄音", skipRefine: true)
            return
        }
        recovering = true
        startRecoveryDeadline()
        // Straight to the keyboard, no cleanup pass. Whatever killed the app last
        // time happened with a sentence already decoded, so this path spends its
        // one shot on delivering rather than on polishing.
        runInjected(url: claimed, detail: "補回上次的錄音", skipRefine: true)
    }

    /// Removes a spool that cannot even be opened.
    ///
    /// A file that fails to open fails identically on every launch, and it is the
    /// newest orphan, so recovery would pick it again and again while the older,
    /// complete spool behind it never got a turn. A *conversion* failure is not
    /// that: it can be transient, and deleting the file would throw the sentence
    /// away. Only spools are touched -- never a file the test flag pointed at.
    private static func discardIfUnreadable(_ url: URL) {
        guard isSpool(url), (try? AVAudioFile(forReading: url)) == nil else { return }
        // A killed process never closes the file, so the header can be short while
        // the data chunk is complete -- `readMono16k` recovers those. If the salvage
        // path can still turn this into samples, it is not an unreadable file.
        if let salvaged = salvageRawWAV(url), !salvaged.isEmpty { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// An empty file decodes to nothing on every launch, so it goes -- otherwise
    /// it stays the newest orphan and blocks the ones behind it.
    private static func removeSpool(_ url: URL) {
        guard isSpool(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isSpool(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == AudioSpool.directory.standardizedFileURL
    }

    /// Any WAV/CAF/M4A at any rate, as 16 kHz mono float32.
    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        // A spool whose process was killed mid-recording may still be headerless
        // in practice: AVAudioFile writes the WAV header's length when the file is
        // closed, and a killed process never closes it. The audio is all there;
        // only the claim about how much there is was never made. Reading the data
        // chunk directly is what turns "the sentence is on disk" into "the
        // sentence comes back".
        if file.length == 0, let salvaged = salvageRawWAV(url), !salvaged.isEmpty {
            Diagnostics.log.notice("spool had no usable header; read the data chunk directly")
            return salvaged
        }
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

    /// Reads the `data` chunk of a WAV straight off disk.
    ///
    /// The payload is little-endian float32, which is exactly what the spool
    /// writes, so no conversion is needed -- and none is possible, because the
    /// point of this path is that the file's own description of itself is wrong.
    private static func salvageRawWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let marker = data.range(of: Data("data".utf8)),
              marker.upperBound + 4 < data.count
        else { return nil }
        let start = marker.upperBound + 4          // skip the chunk's declared size
        let payload = data[start...]
        let count = payload.count / 4
        guard count > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in 0..<count {
                let bits = base.loadUnaligned(
                    fromByteOffset: index * 4, as: UInt32.self
                )
                samples[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return samples
    }

    // MARK: pieces

    /// `ASR_Stop` returns the whole session; `accumulated` is that same session
    /// as this side built it, one closed utterance at a time.
    ///
    /// They are the same words, but not the same string: the core joins
    /// utterances with `join_speech`, which inserts a space at a boundary that
    /// is not Chinese-to-Chinese, while this side simply concatenates. So
    /// "中文Notion" and "中文 Notion" are the same sentence spelled differently,
    /// and neither is a prefix of the other -- the old code then did
    /// `accumulated + final` and every dictation containing an English word was
    /// typed twice ("開會用 Notion 記錄開會用 Notion 記錄"). `final` covers every
    /// utterance, so it is the one to keep; `accumulated` only matters when the
    /// core returned nothing.
    static func merge(_ accumulated: String, _ final: String) -> String {
        final.isEmpty ? accumulated : final
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
