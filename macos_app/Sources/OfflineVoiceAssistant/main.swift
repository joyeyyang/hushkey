import AppKit
import Foundation

/// Coordinates setup -> hotkey -> mic -> core ASR -> LLM polish -> text injection.
/// Core and audio calls run on coreQueue; all UI updates run on the main thread.
final class AppController {
    private let keywords = Keywords()
    private let history = HistoryStore()
    private let hud = HUDWindow()
    /// The live, verbatim transcript. Shown for both dictation and meeting mode;
    /// closing it never stops the recording.
    private let transcriptWindow = TranscriptWindow()
    /// The raw transcript behind the result currently being delivered, kept so
    /// history can store both the original wording and the cleaned-up line.
    private var lastRawTranscript = ""
    private var statusItem: StatusItem?
    private var mainWindow: MainWindow?
    private var capture: AudioCapture?
    /// Records what the Mac plays during a meeting, so the other side of the
    /// call is transcribed too. Only active when the setting is on.
    private var systemTap: SystemAudioTap?
    private var hotkey: Hotkey?
    private var dictating = false
    private var meeting = false
    /// True between a start being requested and the ASR session actually being up.
    /// `dictating`/`meeting` are set on the main queue after an async hop, so a
    /// second hotkey press inside that window passes both guards, starts a second
    /// ASR session (rejected as "session already active") and replaces the
    /// recorder without stopping the first. This claim is taken synchronously.
    private var sessionStarting = false
    /// Non-fatal problems that happened during the meeting currently being
    /// recorded (e.g. the system-audio tap was refused). Kept so the saved file
    /// and the final message can say what is missing from the recording.
    private var meetingWarnings: [String] = []
    private var ready = false
    private var loading = false
    private var permissionTimer: Timer?
    private var permissionTicks = 0
    private var lastTrust: Bool?
    private let coreQueue = DispatchQueue(label: "ovc.core")

    /// Live character-count poll while recording.
    private var liveCountTimer: Timer?
    private var peeking = false
    private var recordingStart = Date()

    private static let hotkeyKey = "settings.hotkey"
    private static let themeKey = "settings.theme"
    private static let polishKey = "settings.polish"
    private static let confirmKey = "settings.confirmInsert"
    private static let translateKey = "settings.translate"
    private static let systemAudioKey = "settings.meetingSystemAudio"

    /// "off", "en" (translate into English) or "zh" (into 繁體中文).
    private var translateTarget: String { UserDefaults.standard.string(forKey: Self.translateKey) ?? "off" }

    /// Whether meeting mode also captures the Mac's own audio output. Default on.
    private var meetingSystemAudio: Bool {
        UserDefaults.standard.object(forKey: Self.systemAudioKey) as? Bool ?? true
    }

    /// Action requested before models finished loading; run once ready.
    private enum PendingAction { case none, dictation, meeting }
    private var pendingAction: PendingAction = .none

    /// Whether the LLM step is applied. Defaults to on.
    private var polishEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.polishKey) as? Bool ?? true
    }

    /// When true, the result waits in an editable HUD and is inserted on Enter.
    /// Default is false: the text is pasted automatically (Typeless-style).
    private var confirmBeforeInsert: Bool {
        UserDefaults.standard.object(forKey: Self.confirmKey) as? Bool ?? false
    }

    func start() {
        // The main window is the primary UI: a persistent control panel.
        let window = MainWindow(keywords: keywords, history: history)
        window.onToggleDictation = { [weak self] in self?.toggleDictation() }
        window.onToggleMeeting = { [weak self] in self?.toggleMeeting() }
        window.onOpenMeetingsFolder = { [weak self] in self?.openMeetingsFolder() }
        window.onThemeChange = { [weak self] appearance in self?.applyTheme(appearance) }
        window.onHotkeyChange = { [weak self] spec in self?.applyHotkey(spec) }
        window.onPolishChange = { enabled in
            UserDefaults.standard.set(enabled, forKey: Self.polishKey)
            ModelInstaller.log("AI polish set to \(enabled)")
        }
        window.onConfirmChange = { confirm in
            UserDefaults.standard.set(confirm, forKey: Self.confirmKey)
            ModelInstaller.log("confirm-before-insert set to \(confirm)")
        }
        window.onQuit = { NSApp.terminate(nil) }
        window.onRecheckPermission = { [weak self] in self?.refreshPermission(reason: "button") }
        mainWindow = window

        // The capsule's stop button ends the recording without the hotkey.
        hud.onStop = { [weak self] in self?.stopFromCapsule() }

        // Picking an older line out of the history pastes it where the cursor is.
        window.onPasteHistory = { [weak self] text in self?.pasteFromHistory(text) }

        // Translation direction is read straight from UserDefaults at use time by
        // MainWindow's own saveSettings, so this only needs to confirm the change.
        window.onTranslateChange = { code in
            ModelInstaller.log("translate set to \(code)")
        }

        // Meeting mode can also transcribe what the Mac plays (the other people
        // on a call); the microphone is always recorded.
        window.onSystemAudioChange = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: Self.systemAudioKey)
            ModelInstaller.log("meeting system audio set to \(enabled)")
            // Apply it to a meeting that is already running, not just the next one.
            self?.applyMeetingSystemAudioChange(enabled)
        }

        // The menu-bar icon reopens the window and never quits the app.
        statusItem = StatusItem(
            onOpen: { [weak self] in self?.showMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )

        hotkey = Hotkey { [weak self] in self?.toggleDictation() }
        registerSavedHotkey()

        // Restore the persisted appearance, if the user chose one.
        applySavedTheme()
        window.updateState(dictating: false, meeting: meeting)

        // Quitting must not leave the microphone or the system-audio tap open.
        // The tap is a process-wide Core Audio object (and lights the system-audio
        // indicator), and Core holds the ASR stream, so both are closed here
        // rather than left to process teardown.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutdown() }

        // Accessibility is required to paste into other apps; prompt for it and
        // keep the in-window banner up to date while the user grants it.
        lastTrust = nil
        refreshPermission(reason: "startup")
        if !TextInjector.hasAccessibility { TextInjector.requestAccessibility() }
        startPermissionWatch()

        // Test-only path: feed a WAV through the ASR pipeline instead of the mic.
        if let wav = SelfTest.wavPath {
            runSelfTest(wavPath: wav)
        } else if ProcessInfo.processInfo.environment["OVC_SELFTEST_HUD"] != nil {
            // HUD regression without audio: exercise the editable-show path (the
            // one that used to crash) and the auto-paste path, then exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.deliver("HUD 自我測試") }
        } else {
            window.center()
            showMainWindow()
            // Preload the models so the status reaches "就緒" and the first
            // dictation is instant.
            ensureModelsLoaded()
        }
    }

    func showMainWindow() {
        guard let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Anything dictated while the window was closed should show up now.
        window.refreshHistory()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keeps the in-window Accessibility banner honest. Polls slowly (so granting
    /// the permission in System Settings clears it without a restart) and also
    /// re-checks whenever the app returns to the foreground.
    private func startPermissionWatch() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPermission(reason: "activated") }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.permissionTicks += 1
            self.refreshPermission(reason: "poll")
            if self.permissionTicks >= 150 { // ~5 min, then rely on activation
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    /// Reads the live Accessibility state and updates the banner + log.
    private func refreshPermission(reason: String) {
        let granted = TextInjector.hasAccessibility
        if lastTrust != granted {
            ModelInstaller.log("accessibility trusted: \(granted) (\(reason))")
            lastTrust = granted
        }
        mainWindow?.setAccessibilityGranted(granted)
    }

    private func registerSavedHotkey() {
        let spec = UserDefaults.standard.string(forKey: Self.hotkeyKey) ?? "Option+Space"
        if hotkey?.register(spec) != true {
            ModelInstaller.log("hotkey '\(spec)' could not be registered; falling back to Option+Space")
            _ = hotkey?.register("Option+Space")
        }
    }

    /// Re-registers the global hotkey at runtime (called from Settings).
    func applyHotkey(_ spec: String) {
        let previous = hotkey?.spec?.display
        if hotkey?.register(spec) == true {
            ModelInstaller.log("hotkey registered: \(spec)")
        } else {
            ModelInstaller.log("invalid hotkey '\(spec)'; keeping \(previous ?? "none")")
            if let previous { _ = hotkey?.register(previous) }
        }
    }

    private func applySavedTheme() {
        guard let code = UserDefaults.standard.string(forKey: Self.themeKey) else { return }
        switch code {
        case "light": applyTheme(NSAppearance(named: .aqua))
        case "dark": applyTheme(NSAppearance(named: .darkAqua))
        default: applyTheme(nil)
        }
    }

    var isDictating: Bool { dictating }
    var isMeeting: Bool { meeting }

    // MARK: - Public actions

    func toggleDictation() {
        // One ASR session at a time. Without this guard the ASR call is rejected
        // with "session already active" and the capsule sticks on the error, while
        // the microphone that is already recording keeps going. The second half of
        // the guard covers the window between the start request and the session
        // being up, when neither `dictating` nor `meeting` is set yet.
        guard !meeting, !sessionStarting else {
            if meeting { hud.notice("會議錄音中，請先結束會議") }
            return
        }
        if !ready { pendingAction = .dictation; ensureModelsLoaded(); return }
        if dictating { stopDictation() } else { startDictation() }
    }

    func toggleMeeting() {
        guard !dictating, !sessionStarting else {
            if dictating { hud.notice("聽寫中，請先結束聽寫") }
            return
        }
        if !ready { pendingAction = .meeting; ensureModelsLoaded(); return }
        if meeting { stopMeeting() } else { startMeeting() }
    }

    func openMeetingsFolder() {
        NSWorkspace.shared.open(meetingsDirectory())
    }

    /// Stops every audio source and closes the core, on the way out.
    ///
    /// A meeting that is still running cannot be transcribed here -- the ASR pass
    /// and the summary take longer than macOS allows a terminating app -- so the
    /// recording is cut off and the log says so; the file is not half-written
    /// because nothing was being written yet.
    private func shutdown() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        stopLiveCount()
        capture?.stop()
        capture = nil
        systemTap?.stop()
        systemTap = nil
        if meeting || dictating {
            ModelInstaller.log("shutdown while recording: \(meeting ? "meeting" : "dictation") discarded")
        }
        Core.shutdown()
    }

    // MARK: - 主題套用

    /// Applies the appearance to the main window only. The HUD panel is left
    /// untouched so its translucent, rounded background keeps working.
    private func applyTheme(_ appearance: NSAppearance?) {
        guard let window = mainWindow else { return }
        window.appearance = appearance
        if appearance == nil {
            window.backgroundColor = .windowBackgroundColor
            window.contentView?.layer?.backgroundColor = nil
        } else {
            let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bgColor: NSColor = isDark
                ? NSColor.black
                : NSColor(calibratedRed: 245/255, green: 240/255, blue: 230/255, alpha: 1)
            window.backgroundColor = bgColor
            window.contentView?.layer?.backgroundColor = bgColor.cgColor
        }
    }

    // MARK: - Model loading (lazy)

    private func ensureModelsLoaded() {
        if ready || loading { return }
        loading = true
        mainWindow?.setStatus("模型：載入中…")
        hud.show(text: "載入模型中…")
        coreQueue.async {
            do {
                let dir = try Self.modelsDirectory { msg in
                    // Download/verify progress comes from a background thread.
                    DispatchQueue.main.async {
                        self.mainWindow?.setStatus("模型：\(msg)")
                        self.hud.show(text: msg)
                    }
                }
                // The core spawns ovc-llm-worker with Command::new, so the worker
                // inherits this process's environment. Setting OVC_LLM_MODEL here --
                // before the first refine -- is what makes the user's model choice
                // reach the engine; passing it to a spawn call would reach nothing.
                LLMSelection.applyToProcessEnvironment()
                try Core.initialize(modelsDir: dir.path)
                try Core.loadASR()
                ModelInstaller.log("core ready: \(dir.path) llm=\(LLMSelection.currentFileName)")
                DispatchQueue.main.async {
                    self.loading = false
                    self.ready = true
                    ModelInstaller.log("ready")
                    self.mainWindow?.setStatus("模型：就緒")
                    self.hud.hide()
                    // Run the action the user asked for before loading finished.
                    let pending = self.pendingAction
                    self.pendingAction = .none
                    switch pending {
                    case .dictation: self.startDictation()
                    case .meeting: self.startMeeting()
                    case .none: break
                    }
                }
            } catch {
                ModelInstaller.log("setup failed: \(error)")
                DispatchQueue.main.async {
                    self.loading = false
                    self.ready = false
                    self.mainWindow?.setStatus("模型：載入失敗")
                    self.hud.show(text: "載入失敗: \(error)")
                    self.pendingAction = .none
                }
            }
        }
    }

    /// Reflects recording state in the window buttons and the menu-bar icon.
    private func setRecordingState() {
        mainWindow?.updateState(dictating: dictating, meeting: meeting)
        statusItem?.updateState(dictating: dictating, meeting: meeting)
    }

    // MARK: - Dictation

    private func startDictation() {
        // A session the user asked for may show the capsule again, even if the
        // previous one was dismissed with Escape.
        hud.allowShowingAgain()
        guard AudioCapture.microphoneAuthorized() else {
            AudioCapture.requestMicrophone { granted in
                DispatchQueue.main.async {
                    self.hud.flash(granted ? "已授權麥克風，再按一次開始" : "麥克風權限被拒絕 (系統設定 > 隱私權 > 麥克風)", seconds: 4)
                }
            }
            return
        }
        guard !sessionStarting else { return }
        sessionStarting = true
        coreQueue.async {
            do { try Core.startASR() } catch {
                DispatchQueue.main.async {
                    self.sessionStarting = false
                    self.hud.flash("\(error)", seconds: 5)
                }
                return
            }
            DispatchQueue.main.async {
                self.sessionStarting = false
                self.dictating = true
                self.setRecordingState()
                self.hud.startRecording()
                self.transcriptWindow.begin(title: "聽寫", status: "辨識中…")
                self.startLiveCount()
                let cap = AudioCapture(
                    onSamples: { [weak self] samples in
                        self?.coreQueue.async { try? Core.submit(samples) }
                    },
                    onLevel: { [weak self] level in
                        DispatchQueue.main.async { self?.hud.setLevel(level) }
                    }
                )
                self.capture = cap
                do { try cap.start() } catch {
                    self.hud.flash("麥克風錯誤: \(error)")
                    self.stopLiveCount()
                    self.dictating = false
                    self.setRecordingState()
                    self.capture = nil
                    // End the ASR session we just started, otherwise every later
                    // start would be rejected with "session already active".
                    self.coreQueue.async { _ = try? Core.stopASR() }
                }
            }
        }
    }

    private func stopDictation() {
        capture?.stop()
        capture = nil
        dictating = false
        stopLiveCount()
        setRecordingState()
        hud.show(text: "轉錄中…")
        finishTranscriptWindow(status: "辨識完成", labelled: false)
        coreQueue.async {
            do {
                let text = try Core.stopASR()
                DispatchQueue.main.async { self.deliver(text) }
            } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
            }
        }
    }

    // MARK: - Meeting (long recording -> saved transcript + best-effort summary)

    private func startMeeting() {
        hud.allowShowingAgain()
        guard AudioCapture.microphoneAuthorized() else {
            AudioCapture.requestMicrophone { granted in
                DispatchQueue.main.async {
                    self.hud.flash(granted
                        ? "已授權麥克風，再按一次開始會議"
                        : "麥克風權限被拒絕 (系統設定 > 隱私權 > 麥克風)", seconds: 4)
                }
            }
            return
        }
        guard !sessionStarting else { return }
        sessionStarting = true
        coreQueue.async {
            do { try Core.startASR() } catch {
                DispatchQueue.main.async {
                    self.sessionStarting = false
                    self.hud.flash("\(error)", seconds: 5)
                }
                return
            }
            DispatchQueue.main.async {
                self.sessionStarting = false
                self.meeting = true
                self.dictating = false
                self.meetingWarnings = []
                self.setRecordingState()
                self.hud.startRecording()
                self.transcriptWindow.begin(title: "會議逐字稿", status: "錄音中…")
                self.startLiveCount()
                let cap = AudioCapture(
                    onSamples: { [weak self] samples in
                        self?.coreQueue.async { try? Core.submit(samples) }
                    },
                    onLevel: { [weak self] level in
                        DispatchQueue.main.async { self?.hud.setLevel(level) }
                    }
                )
                self.capture = cap
                do { try cap.start() } catch {
                    self.hud.flash("麥克風錯誤: \(error)")
                    self.stopLiveCount()
                    self.meeting = false
                    self.setRecordingState()
                    self.capture = nil
                    self.coreQueue.async { _ = try? Core.stopASR() }
                    return
                }
                self.startSystemTap()
            }
        }
    }

    /// Starts the system-audio tap alongside the microphone, if the user asked
    /// for it. A failure here is never fatal: the meeting keeps recording the
    /// microphone, and the reason goes to the window and the log.
    ///
    /// The capsule shows one short line -- the long reason names a System
    /// Settings path and does not fit in 190 pt -- and the full text goes to the
    /// window and the log. `hud.notice` is used rather than `hud.flash`: it does
    /// not take the recording away.
    private func startSystemTap() {
        guard meetingSystemAudio else { return }
        guard SystemAudioTap.isSupported else {
            reportSystemAudioFailure("此 macOS 版本不支援錄製電腦播放的聲音（需要 macOS 14.2 以上），這次只錄麥克風。")
            return
        }
        let tap = SystemAudioTap(onSamples: { [weak self] samples in
            self?.coreQueue.async { try? Core.submit(samples, speaker: .other) }
        })
        do {
            try tap.start()
            systemTap = tap
            ModelInstaller.log("meeting system audio tap started")
        } catch {
            reportSystemAudioFailure(error.localizedDescription)
        }
    }

    /// Explains a system-audio failure: short line in the capsule, full text in
    /// the main window and the log, since only one of those is wide enough. The
    /// capsule line is also remembered so the meeting's own summary can say the
    /// other side of the call is missing.
    private func reportSystemAudioFailure(_ reason: String) {
        let message = "只錄麥克風：\(reason)"
        ModelInstaller.log("meeting system audio tap failed: \(reason)")
        meetingWarnings.append("系統音訊未錄到（\(reason)）")
        hud.notice("系統音訊未錄到，只錄麥克風", seconds: 5)
        mainWindow?.setTranscript(message)
    }

    /// Applies a change to the "record the Mac's own audio" setting while a
    /// meeting is already running, so the checkbox is not silently deferred to
    /// the next meeting.
    private func applyMeetingSystemAudioChange(_ enabled: Bool) {
        guard meeting else { return }
        if enabled {
            guard systemTap == nil else { return }
            startSystemTap()
        } else if let tap = systemTap {
            tap.stop()
            systemTap = nil
            ModelInstaller.log("meeting system audio tap stopped by setting")
        }
    }

    private func stopMeeting() {
        capture?.stop()
        capture = nil
        systemTap?.stop()
        systemTap = nil
        meeting = false
        stopLiveCount()
        setRecordingState()
        hud.show(text: "整理會議中…長會議需要幾分鐘")
        finishTranscriptWindow(status: "錄音結束", labelled: true)
        coreQueue.async {
            do {
                let transcript = try Core.stopASR()
                // Nothing was picked up: a saved file would be an empty record
                // that reads like a successful meeting.
                let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else {
                    DispatchQueue.main.async {
                        self.hud.flash("沒有錄到聲音，未儲存會議記錄", seconds: 5)
                        self.mainWindow?.setTranscript("（這次會議沒有錄到聲音，未儲存檔案。）")
                    }
                    return
                }
                let saved = try self.saveMeeting(transcript)
                DispatchQueue.main.async {
                    self.mainWindow?.setTranscript(transcript)
                    if self.meetingWarnings.isEmpty {
                        self.hud.flash("已儲存會議記錄：\(saved.lastPathComponent)", seconds: 4)
                    } else {
                        self.hud.flash("已儲存（部分內容未錄到，詳見紀錄）", seconds: 5)
                    }
                    self.meetingWarnings = []
                }
            } catch {
                DispatchQueue.main.async { self.hud.flash("\(error)", seconds: 5) }
            }
        }
    }

    // MARK: - Live capsule readout

    /// Polls the engine for freshly decoded utterances.
    ///
    /// Two jobs in one thread hop, for one reason: `takeSegments` is what makes
    /// the engine segment and decode the audio it has queued, and `peek` is then
    /// just a join over the utterances that already exist. Polling only `peek`
    /// (as this used to) shows an empty transcript, because nothing ever asked
    /// the engine to decode.
    private func startLiveCount() {
        stopLiveCount()
        recordingStart = Date()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Stops itself when the session ends; a long meeting must keep
            // polling, so this is not a duration limit.
            guard self.dictating || self.meeting else { self.stopLiveCount(); return }
            if self.peeking { return }
            self.peeking = true
            self.coreQueue.async {
                let segments = (try? Core.takeSegments()) ?? []
                let text = (try? Core.peekASR()) ?? ""
                DispatchQueue.main.async {
                    self.peeking = false
                    self.hud.setCount(text.count)
                    self.transcriptWindow.append(segments, showSpeaker: self.meeting)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveCountTimer = timer
    }

    /// `ASR_Stop` decodes the last utterance itself, after the final poll, so one
    /// more drain is what puts the closing sentence in the window.
    ///
    /// `labelled` is passed in rather than read from `meeting`, because the caller
    /// clears that flag before the session ends.
    private func finishTranscriptWindow(status: String, labelled: Bool) {
        self.coreQueue.async {
            let tail = (try? Core.takeSegments()) ?? []
            DispatchQueue.main.async {
                self.transcriptWindow.append(tail, showSpeaker: labelled)
                self.transcriptWindow.finish(status: status)
            }
        }
    }

    private func stopLiveCount() {
        liveCountTimer?.invalidate()
        liveCountTimer = nil
    }

    /// The capsule's stop button: end whichever kind of recording is running.
    private func stopFromCapsule() {
        if meeting {
            stopMeeting()
        } else if dictating {
            stopDictation()
        }
    }

    /// Writes the transcript to the meetings folder and, best-effort, a summary.
    @discardableResult
    private func saveMeeting(_ transcript: String) throws -> URL {
        let dir = meetingsDirectory()
        let stamp = Self.stampFormatter.string(from: Date())
        // The recognizer and the model both drift into Simplified; the file is
        // for a Taiwanese reader, so normalize once here rather than in each pass.
        let traditional = toTraditional(transcript)
        let txt = dir.appendingPathComponent("meeting-\(stamp).txt")
        try traditional.write(to: txt, atomically: true, encoding: .utf8)
        // Summary is optional: a long transcript spawns several worker passes,
        // each of which reloads the model. Failure just means no .md file.
        if !traditional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let summary = try? Core.summarize(traditional), !summary.isEmpty {
            let md = dir.appendingPathComponent("meeting-\(stamp).md")
            // A meeting recorded without the system-audio tap is missing the
            // other side of the call. Say so in the file: a reader cannot tell a
            // one-sided transcript from a quiet room.
            let caveat = meetingWarnings.isEmpty
                ? ""
                : "> 錄音提示：\(self.meetingWarnings.joined(separator: "；"))\n\n"
            try? "\(caveat)\(toTraditional(summary))\n\n---\n\n\(traditional)\n"
                .write(to: md, atomically: true, encoding: .utf8)
        }
        return txt
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - Delivery

    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRawTranscript = trimmed
        // Regression self-test: exercise both HUD paths (the editable show that
        // used to crash with doesNotRecognizeSelector, and the auto-paste path)
        // and exit cleanly if the app survives.
        if ProcessInfo.processInfo.environment["OVC_SELFTEST_HUD"] != nil {
            let sample = trimmed.isEmpty ? "test" : trimmed
            hud.show(text: sample, mode: .edit) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.insertDirect(sample) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
            return
        }
        if SelfTest.wavPath != nil {
            // ASR-only by default. With OVC_SELFTEST_POLISH the run continues
            // through refine + paste, so the whole pipeline can be checked.
            guard SelfTest.runsFullPipeline else {
                ModelInstaller.log("selftest result: \(trimmed)")
                exit(trimmed.isEmpty ? 4 : 0)
            }
            ModelInstaller.log("selftest transcript: \(trimmed)")
            SelfTest.exitsWhenDone = true
            present(trimmed)
            return
        }
        guard !trimmed.isEmpty else {
            hud.flash("未偵測到語音")
            return
        }
        present(trimmed)
    }

    /// Polishes the transcript off the main thread (the LLM worker blocks for
    /// seconds while it loads the model), then inserts it.
    private func present(_ trimmed: String) {
        // Normalise Chinese to Traditional up front: SenseVoice emits Simplified,
        // and the LLM otherwise just mirrors whatever script it is given.
        let text = toTraditional(trimmed)
        guard polishEnabled else {
            finish(text)
            return
        }
        hud.show(text: translateTarget == "off" ? "AI 整理中…" : "整理並翻譯中…")
        coreQueue.async {
            let polished = self.translateIfNeeded(self.polish(text))
            DispatchQueue.main.async { self.finish(polished) }
        }
    }

    /// Translate the finished line when the user asked for it. It runs as its own
    /// model pass AFTER the refine pass: refine must not change the language,
    /// translation must, and asking one prompt to do both produced drafts that
    /// came back half-translated. A translation that fails, or that comes back as
    /// a note instead of a translation, falls back to the cleaned text so the
    /// dictation is never lost.
    private func translateIfNeeded(_ text: String) -> String {
        let target = translateTarget
        guard target == "en" || target == "zh" else { return text }
        guard let raw = try? Core.translate(text, to: target) else {
            ModelInstaller.log("translate unavailable; keeping the cleaned text")
            return text
        }
        let translated = normalizeOutput(toTraditional(stripLabel(raw.trimmingCharacters(in: .whitespacesAndNewlines))))
        // The model sometimes answers with an explanation instead of a
        // translation; the target script must actually be present, and a
        // translation that is five times the original is a note, not a line.
        let hasLatin = translated.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        let plausible = (target == "en") ? hasLatin : translated.containsCJK
        guard !translated.isEmpty, plausible, translated.count <= text.count * 5 else {
            ModelInstaller.log("translate output looked wrong; keeping the cleaned text")
            return text
        }
        ModelInstaller.log("translated to \(target): \(preview(translated))")
        return translated
    }

    /// Shows the result in the window and either inserts it immediately or (if
    /// the user asked to confirm first) shows an editable HUD and waits for Enter.
    private func finish(_ polished: String) {
        mainWindow?.setTranscript(polished)
        recordHistory(polished)
        if SelfTest.exitsWhenDone { ModelInstaller.log("selftest polished: \(polished)") }
        // A full-pipeline self-test always pastes directly: the saved "confirm
        // first" preference would otherwise leave it waiting for an Enter key
        // press that a scripted run never sends.
        if confirmBeforeInsert && !SelfTest.exitsWhenDone {
            hud.show(text: polished, mode: .edit) { [weak self] in
                guard let self = self else { return }
                self.insertAfterHidingHUD(self.hud.getDisplayedText())
            }
        } else {
            insertDirect(polished)
        }
    }

    /// Inserts text into whatever app was focused. The HUD is in display mode here
    /// (not key), so the synthesized Cmd+V lands in the target app, not in us.
    private func insertDirect(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hud.flash("內容為空，已忽略")
            return
        }
        switch TextInjector.insert(trimmed) {
        case .pasted:
            ModelInstaller.log("insert: pasted \(trimmed.count) chars")
            refreshPermission(reason: "paste")
            hud.showResult(trimmed)
        case let .needsPermission(reason):
            ModelInstaller.log("insert: blocked - accessibility not granted")
            // Bring the window up so the banner and its buttons are visible.
            refreshPermission(reason: "paste-blocked")
            hud.show(text: "\(trimmed)\n(\(reason))", mode: .display)
            showMainWindow()
        case let .copiedOnly(reason):
            ModelInstaller.log("insert: copied only (\(reason))")
            hud.show(text: "\(trimmed)\n(\(reason))", mode: .display)
        }
        if SelfTest.exitsWhenDone {
            // Let the synthesized Cmd+V reach the target app before quitting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ModelInstaller.log("selftest done")
                exit(0)
            }
        }
    }

    // MARK: - History

    /// Stores a finished line so it can be found and pasted again later. Skipped
    /// during scripted self-tests, which would otherwise fill the list with
    /// their own fixtures.
    private func recordHistory(_ polished: String) {
        guard !isSelfTest else { return }
        history.add(HistoryEntry(date: Date(), polished: polished, raw: lastRawTranscript))
        mainWindow?.refreshHistory()
    }

    /// Paste a line the user picked out of the history list. The window has to
    /// get out of the way first, otherwise the synthesized paste lands in our
    /// own list instead of the app the user was working in.
    private func pasteFromHistory(_ text: String) {
        mainWindow?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.hud.showResult(text, seconds: 2.2)
            self.insertDirect(text)
        }
    }

    private var isSelfTest: Bool {
        SelfTest.wavPath != nil || ProcessInfo.processInfo.environment["OVC_SELFTEST_HUD"] != nil
    }

    /// Editable-HUD path: hide the HUD first so the paste does not land in our
    /// own text field (which would duplicate the text).
    private func insertAfterHidingHUD(_ text: String) {        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hud.show(text: "內容為空，已忽略")
            return
        }
        hud.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.insertDirect(trimmed)
        }
    }

    /// Runs the LLM refinement, but falls back to the raw transcript when the
    /// output is empty or obviously corrupt. The bundled model is small, so this
    /// safety guard prevents it from silently dropping, inventing, or translating content.
    private func polish(_ raw: String) -> String {
        let hint = keywords.hintString()
        let stages = Self.refineStagesOverride()
        guard let refined = try? Core.refineWithKeywords(raw, keywordsHint: hint, stages: stages) else {
            ModelInstaller.log("refine unavailable; using raw transcript")
            return fallback(raw)
        }
        // Convert again after the model: it may echo Simplified even when asked not to.
        let candidate = normalizeOutput(toTraditional(stripLabel(refined.trimmingCharacters(in: .whitespacesAndNewlines))))
        let verdict = sanityCheck(candidate, comparedTo: raw)
        guard verdict.ok else {
            ModelInstaller.log("refine rejected (\(verdict.reason)) | raw=\(preview(raw)) | candidate=\(preview(candidate))")
            return fallback(raw)
        }
        ModelInstaller.log("refine kept: \(raw.count)->\(candidate.count) chars, \(description(of: stages))")
        return candidate
    }

    /// The raw transcript, tidied just enough to paste. Used whenever the model's
    /// answer is thrown away, so a rejected refine still pastes Traditional
    /// Chinese with one consistent bullet style instead of whatever the speech
    /// recogniser happened to emit.
    private func fallback(_ raw: String) -> String {
        normalizeOutput(toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Housekeeping on the model's text before it is pasted: one newline style,
    /// plain "• " bullets instead of Markdown dashes or asterisks (the text goes
    /// into any app, so it must not depend on a Markdown renderer), and no bold
    /// markers.
    private func normalizeOutput(_ text: String) -> String {
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "・", "· ", "•"] where trimmed.hasPrefix(marker) {
                trimmed = "• " + trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                break
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "**", with: "")
    }

    /// How many model passes to ask the engine for. 0 means "decide by length";
    /// `OVC_REFINE_STAGES=1|2` forces one shape so both can be compared on the
    /// same input.
    private static func refineStagesOverride() -> UInt32 {
        switch ProcessInfo.processInfo.environment["OVC_REFINE_STAGES"] {
        case "1": return 1
        case "2": return 2
        default: return 0
        }
    }

    /// Label for the log line only; the engine owns the actual rule.
    private func description(of stages: UInt32) -> String {
        switch stages {
        case 1: return "single pass (forced)"
        case 2: return "two-stage (forced)"
        default: return "single pass (default)"
        }
    }

    /// Guards against the two ways a small model betrays us: answering the
    /// transcript instead of cleaning it (empty output, meta phrasing, a
    /// different language), and inventing content that was never said.
    ///
    /// Deliberately permissive about DELETION. Condensing away filler,
    /// repetition and whole redundant clauses is the entire point of this
    /// feature, and the old length-ratio floor was rejecting exactly that --
    /// three ordinary dictations in a row came back as raw transcripts.
    private func sanityCheck(_ refined: String, comparedTo raw: String) -> (ok: Bool, reason: String) {
        guard !refined.isEmpty else { return (false, "empty output") }

        let rawLen = max(raw.count, 1)
        let refinedLen = refined.count
        if refinedLen < Int(Double(rawLen) * 0.15) {
            return (false, "far too short: \(refinedLen)/\(rawLen) chars")
        }
        if refinedLen > Int(Double(rawLen) * 2.0) {
            return (false, "far too long: \(refinedLen)/\(rawLen) chars")
        }
        for prefix in ["以下是", "很抱歉", "抱歉", "對不起", "總結：", "原文：", "Here is", "Sure,"] where refined.hasPrefix(prefix) {
            return (false, "meta phrasing: \(prefix)")
        }
        if let leaked = leakedInstruction(refined, raw: raw) {
            return (false, "echoed the instructions: \(leaked)")
        }

        if raw.containsCJK {
            guard refined.containsCJK else { return (false, "no Chinese left in the output") }
            let rawCJK = Set(raw.unicodeScalars.filter(\.isCJK))
            if !rawCJK.isEmpty {
                let refinedSet = Set(refined.unicodeScalars)
                let kept = rawCJK.filter { refinedSet.contains($0) }.count
                let ratio = Double(kept) / Double(rawCJK.count)
                // Condensing to ~30% of the original length is normal, and the
                // legitimate worst case measured 0.26 -- so 0.25 was rejecting
                // good answers by a hair. This only has to catch the model
                // rewriting the draft into something else entirely.
                if ratio < 0.18 {
                    return (false, "only kept \(Int(ratio * 100))% of the words used")
                }
            }
        } else if raw.containsLatinLetter {
            // A non-Chinese transcript must not be translated away.
            guard refined.containsLatinLetter else { return (false, "translated away") }
        }
        return (true, "ok")
    }

    /// Distinctive phrases from the refine instructions in `core_engine/src/llm.rs`
    /// (`REFINE_SYSTEM`). If the answer repeats one of these and the user never
    /// said it, the model answered US instead of cleaning the draft -- which was
    /// observed when the draft itself was about writing prompts. The raw check
    /// keeps a legitimate dictation about those rules from being rejected.
    private static let instructionPhrases = [
        "不要摘要", "不要漏掉任何一件事", "重複講的同一件事只留一次", "刪掉口頭禪",
        "多餘的字", "照原樣保留", "問句保持問句", "語言跟原文相同",
        "把使用者的口語改寫成通順的書面文字",
    ]

    /// Returns the leaked phrase, or nil when the answer looks like a real edit.
    private func leakedInstruction(_ refined: String, raw: String) -> String? {
        for phrase in Self.instructionPhrases where refined.contains(phrase) && !raw.contains(phrase) {
            return phrase
        }
        return nil
    }

    /// One-line excerpt for the log so a rejection can be diagnosed later.
    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 160 ? flat : String(flat.prefix(160)) + "…"
    }

    /// Converts Simplified Chinese to Traditional using macOS's built-in ICU
    /// transform. Deterministic and offline, so the LLM never has to do it.
    /// A no-op for text without Han characters (e.g. English).
    private func toTraditional(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
        return mutable as String
    }

    /// Removes a leading "潤飾：" / "Output:"-style label the small model may echo
    /// from the prompt examples.
    private func stripLabel(_ text: String) -> String {
        for label in ["整理：", "整理:", "潤飾：", "潤飾:", "草稿：", "草稿:", "輸出：", "Output:", "Polished:",
                      "翻譯：", "翻譯:", "Translation:", "英文：", "中文："] {
            if text.hasPrefix(label) {
                return String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    // MARK: - Test-only WAV path

    /// Feeds a 16 kHz mono WAV through the same ASR path the microphone uses,
    /// then delivers the transcript. Enabled by the OVC_SELFTEST_WAV env var.
    private func runSelfTest(wavPath: String) {
        ModelInstaller.log("selftest: wav=\(wavPath)")
        hud.show(text: "自我測試中…")
        coreQueue.async {
            do {
                let dir = try Self.modelsDirectory { ModelInstaller.log($0) }
                try Core.initialize(modelsDir: dir.path)
                try Core.loadASR()
                let samples = try SelfTest.readWav(URL(fileURLWithPath: wavPath))
                try Core.startASR()
                let chunk = 16_000
                var i = 0
                while i < samples.count {
                    let end = min(i + chunk, samples.count)
                    try Core.submit(Array(samples[i..<end]))
                    i = end
                }
                let text = try Core.stopASR()
                DispatchQueue.main.async { self.deliver(text) }
            } catch {
                ModelInstaller.log("selftest failed: \(error)")
                exit(5)
            }
        }
    }

    // MARK: - Model directory & meetings directory

    static func modelsDirectory(progress: @escaping (String) -> Void) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["OVC_MODELS"] { return URL(fileURLWithPath: dir) }
        let base: URL
        if let dataDir = env["OVC_DATA_DIR"] {
            base = URL(fileURLWithPath: dataDir)
        } else {
            base = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OfflineVoiceAssistant")
        }
        let root = base.appendingPathComponent("models")
        try ModelInstaller.ensureInstalled(root: root, progress: progress)
        return root
    }

    func meetingsDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OfflineVoiceAssistant/meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

private extension Unicode.Scalar {
    var isCJK: Bool {
        (0x4E00...0x9FFF).contains(Int(value)) || (0x3400...0x4DBF).contains(Int(value))
    }
}

private extension String {
    var containsCJK: Bool { unicodeScalars.contains { $0.isCJK } }

    var containsLatinLetter: Bool {
        unicodeScalars.contains {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
