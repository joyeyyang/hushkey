import VoiceInputKit
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Coordinates setup -> hotkey -> mic -> core ASR -> LLM polish -> text injection.
/// Core and audio calls run on coreQueue; all UI updates run on the main thread.
final class AppController {
    private let keywords = Keywords()
    private let history = HistoryStore()
    /// The one floating surface for a live session: the capsule's controls with
    /// the verbatim transcript under them. There used to be a second panel for
    /// the transcript, which meant two windows to move, two Escape handlers and
    /// two answers to the same question ("am I still recording?"); a single
    /// window cannot disagree with itself. Escape still only closes it.
    private let hud = DictationWindow()
    /// One importer for the app: the engine has one ASR session, so two file
    /// imports at once would fight each other the same way two recordings do.
    private let audioImporter = AudioFileImporter()
    /// The raw transcript behind the result currently being delivered, kept so
    /// history can store both the original wording and the cleaned-up line.
    private var lastRawTranscript = ""
    private var statusItem: StatusItem?
    private var mainWindow: MainWindow?
    /// The packaged pipeline, and the only thing that touches audio or the core:
    /// it points the core at the model tree, publishes the LLM choice into the
    /// process environment the worker inherits, and loads the ASR model. Every
    /// recording is one of its sessions, so capture, segmentation, the
    /// system-audio tap and the ASR lifecycle have one implementation instead of
    /// a copy per mode.
    private var engine: VoiceInputEngine?
    /// The recording in progress, if any. Dictation and meeting are the same
    /// session with different settings; only what happens to the transcript at
    /// the end differs.
    private var session: VoiceInputSession?
    /// The text this app last handed to another app, so a spoken edit
    /// instruction ("第二點改成禮拜五") has something to apply itself to.
    private var lastDelivery: String?
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
    /// Pause is its own state, not a stop: the ASR session, the buffer and the
    /// finished result all survive, and only the audio feed is cut. The hotkey
    /// deliberately does nothing while paused, so a stray Option+Space during a
    /// meeting cannot end the recording.
    private var paused = false
    /// Last moment the microphone actually carried something, for the silence
    /// warning. Set whenever a level sample clears the floor.
    private var lastSoundAt = Date()
    private var silenceWarned = false
    private var silenceTimer: Timer?
    /// Segments of the current recording, in order. The engine only hands out
    /// segments it has not delivered yet, so this list is append-only and is the
    /// single source of truth for the floating window's transcript and every
    /// export.
    private var sessionSegments: [TranscriptSegment] = []
    private var sessionStartedAt = Date()
    /// The last finished recording in exporter form, kept so 匯出 still works
    /// after the recording is over.
    private var lastSession: SessionExport?
    private var exportSettings = ExportSettings.load()
    private var ready = false
    private var loading = false
    private var permissionTimer: Timer?
    private var permissionTicks = 0
    private var lastTrust: Bool?
    private let coreQueue = DispatchQueue(label: "ovc.core")

    private static let hotkeyKey = "settings.hotkey"
    private static let themeKey = "settings.theme"
    private static let polishKey = "settings.polish"
    private static let confirmKey = "settings.confirmInsert"
    private static let translateKey = "settings.translate"
    private static let toneKey = "settings.tone"
    private static let systemAudioKey = "settings.meetingSystemAudio"

    /// "auto" (the default), "off", "en" (translate into English) or "zh" (into
    /// 繁體中文).
    ///
    /// "auto" is not a translation pass: the refine prompt already answers in
    /// 繁體中文 unless the dictation asks for another language ("整理成英文"), and
    /// asking a second model to translate that answer again would undo it. The
    /// explicit directions stay for people who want every line in one language
    /// regardless of what they said.
    private var translateTarget: String { UserDefaults.standard.string(forKey: Self.translateKey) ?? "auto" }

    /// The register the cleanup writes in: "casual", "normal" or "formal".
    ///
    /// `OVC_REFINE_TONE` overrides the stored value so the three registers can be
    /// compared on the same sentence without opening settings and changing it
    /// back. A value the core does not know is treated as "normal" there, so a
    /// typo costs the register and never the dictation.
    private var refineTone: String {
        if let forced = ProcessInfo.processInfo.environment["OVC_REFINE_TONE"],
           !forced.trimmingCharacters(in: .whitespaces).isEmpty {
            return forced
        }
        return UserDefaults.standard.string(forKey: Self.toneKey) ?? "normal"
    }

    /// Whether meeting mode also captures the Mac's own audio output. Default on.
    private var meetingSystemAudio: Bool {
        UserDefaults.standard.object(forKey: Self.systemAudioKey) as? Bool ?? true
    }

    /// Action requested before models finished loading; run once ready.
    private enum PendingAction { case none, dictation, meeting, importFile(URL) }
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
        window.onThemeChange = { [weak self] in self?.reloadTheme() }
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
        // Export settings live in one blob (ExportSettings) rather than three
        // UserDefaults keys, so MainWindow saves the value it already owns.
        window.onExportSettingsChange = { [weak self] settings in
            settings.save()
            self?.exportSettings = settings
            ModelInstaller.log(
                "export: \(settings.format.rawValue) auto=\(settings.autoSave) folder=\(settings.folder)"
            )
        }
        window.onExportNow = { [weak self] in self?.exportLastSession() }
        mainWindow = window

        // Asked once, up front: naming a recording after the calendar event it
        // belongs to only works if the permission is already granted when the
        // meeting stops, and the prompt must not appear then.
        CalendarNaming.requestAccessIfNeeded { granted in
            ModelInstaller.log("calendar access: \(granted)")
        }

        // The capsule's stop button ends the recording without the hotkey.
        hud.onStop = { [weak self] in self?.stopFromCapsule() }
        hud.onPause = { [weak self] in self?.togglePause() }
        hud.onInsert = { [weak self] in self?.insertFromLiveWindow() }

        window.onResetPermission = { [weak self] in self?.resetAccessibilityPermission() }
        window.onImportAudio = { [weak self] url in self?.importAudioFile(url) }
        window.onManualEdit = { [weak self] instruction, region, draft, selection in
            self?.applyManualEdit(instruction, region: region, to: draft, selection: selection)
        }

        // Picking an older line out of the history pastes it where the cursor is.
        window.onPasteHistory = { [weak self] text in self?.pasteFromHistory(text) }

        // Translation direction is read straight from UserDefaults at use time by
        // MainWindow's own saveSettings, so this only needs to confirm the change.
        window.onTranslateChange = { code in
            ModelInstaller.log("translate set to \(code)")
        }

        // The register reaches the core through `passConfig()`, which reads the
        // same key on every dictation, so nothing has to be pushed anywhere.
        window.onToneChange = { code in
            ModelInstaller.log("refine tone set to \(code)")
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
            onExport: { [weak self] in self?.exportLastSession() },
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
        } else if let wav = ProcessInfo.processInfo.environment["OVC_SELFTEST_MEETING"] {
            // The meeting path: a WAV through a MEETING session, checked for the
            // thing a meeting must not have -- the dictation cleanup run over
            // the transcript.
            runMeetingSelfTest(wavPath: wav)
        } else if let path = ProcessInfo.processInfo.environment["OVC_SELFTEST_IMPORT"] {
            // Headless proof that a file goes through decode -> engine ->
            // segments without a GUI: the same path the 匯入音檔 button takes.
            pendingAction = .importFile(URL(fileURLWithPath: path))
            ensureModelsLoaded()
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
            // The identity is part of the line because "the switch is on and the
            // app says no" is almost always two different copies of the app: the
            // one TCC knows and the one running.
            ModelInstaller.log("accessibility trusted: \(granted) (\(reason)) \(TextInjector.identity)")
            lastTrust = granted
        }
        mainWindow?.setAccessibilityGranted(granted)
    }

    /// Clears this bundle's Accessibility row and asks the system again.
    ///
    /// Needed because the row is bound to the code signature: after a rebuild the
    /// switch in System Settings can read ON while nothing matches the binary
    /// that is running, and the switch cannot be turned off and on again. The
    /// reset is the only way to get a fresh row, and it must be followed by a new
    /// prompt or the app never reappears in the list.
    private func resetAccessibilityPermission() {
        ModelInstaller.log("accessibility reset requested; \(TextInjector.identity)")
        DispatchQueue.global(qos: .userInitiated).async {
            let status = TextInjector.resetAccessibility()
            DispatchQueue.main.async {
                ModelInstaller.log("accessibility reset finished: status \(status)")
                TextInjector.requestAccessibility()
                self.lastTrust = nil
                self.refreshPermission(reason: "after reset")
            }
        }
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
        applyTheme()
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
        guard !audioImporter.isBusy else {
            hud.notice("音檔辨識中，結束後再開始錄音")
            return
        }
        // Paused means "leave me alone": the hotkey neither resumes nor stops.
        // Resuming is the capsule's ▶, which cannot be pressed by accident with
        // the same hand that is writing notes.
        if paused && dictating { return }
        if !ready { pendingAction = .dictation; ensureModelsLoaded(); return }
        if dictating { stopDictation() } else { startDictation() }
    }

    func toggleMeeting() {
        guard !dictating, !sessionStarting else {
            if dictating { hud.notice("聽寫中，請先結束聽寫") }
            return
        }
        guard !audioImporter.isBusy else {
            hud.notice("音檔辨識中，結束後再開始會議")
            return
        }
        if paused && meeting { return }
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
        stopSilenceWatch()
        if meeting || dictating {
            ModelInstaller.log("shutdown while recording: \(meeting ? "meeting" : "dictation") discarded")
        }
        // Ending the session closes the microphone and the system-audio tap, and
        // `shutdown()` releases the core. Both happen here rather than at process
        // teardown, because the tap is a process-wide Core Audio object that
        // lights the system-audio indicator while it exists.
        session?.cancel()
        session = nil
        engine?.shutdown()
    }

    /// The kit's view of this install: where the models are, and which LLM the
    /// engine should load.
    ///
    /// `polishEnabled: false` on purpose. A session only captures and
    /// transcribes; the cleanup chain runs in `present()` instead, which is where
    /// the app can also notice that the dictation was an edit instruction about
    /// the previous result and edit that, rather than polishing an instruction
    /// into a sentence. System audio is switched on per recording
    /// (`setSystemAudioEnabled`), so the session config does not carry it either.
    static func engineConfig(modelsDir: URL) -> VoiceInputConfig {
        VoiceInputConfig(
            modelsDirectory: modelsDir,
            llmModel: LLMSelection.currentFileName,
            polishEnabled: false
        )
    }

    // MARK: - 主題套用

    /// One theme drives every surface: the main window's paper and the floating
    /// window's, capsule and transcript card alike. `ThemeCatalog.current` has
    /// already resolved "system" into a concrete palette, so nothing here is
    /// conditional.
    private func applyTheme() {
        let theme = ThemeCatalog.current
        NSApp.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        mainWindow?.applyTheme(theme)
        hud.applyTheme(theme)
    }

    private func reloadTheme() {
        applyTheme()
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
                // `prepare()` publishes the models directory and the LLM choice
                // into this process's environment -- the only route that reaches
                // the worker, because the core spawns `ovc-llm-worker` with
                // `Command::new` and that child inherits *this* process's
                // environment -- and then loads the ASR model, so the first
                // dictation does not pay for the load.
                let engine = try VoiceInputEngine(config: Self.engineConfig(modelsDir: dir))
                try engine.prepare()
                ModelInstaller.log("core ready: \(dir.path) llm=\(LLMSelection.currentFileName)")
                DispatchQueue.main.async {
                    self.engine = engine
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
                    case let .importFile(url): self.importAudioFile(url)
                    case .none: break
                    }
                }
            } catch {
                ModelInstaller.log("setup failed: \(error)")
                // A headless run has no window to report the failure in, and no
                // run loop that would ever end: exiting is the only way the
                // caller learns it failed instead of waiting forever.
                if ProcessInfo.processInfo.environment["OVC_SELFTEST_IMPORT"] != nil {
                    exit(1)
                }
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

    // MARK: - Pause, and the silence warning

    /// Below this the microphone is carrying room noise, not a voice. The meter
    /// maps -55…0 dBFS onto 0…1, so 0.15 is about -47 dBFS.
    private static let silenceFloor: Float = 0.15
    /// Long enough that a pause in speech is not a warning, short enough that an
    /// entirely muted mic is caught while the user is still in the meeting.
    private static let silenceWarnSeconds: TimeInterval = 12

    /// The one place the level is read: it drives the meter, and it is how the
    /// app knows the microphone has gone quiet.
    private func noteLevel(_ level: Float) {
        DispatchQueue.main.async {
            if level >= Self.silenceFloor {
                self.lastSoundAt = Date()
                self.silenceWarned = false
            }
            guard !self.paused else { return }
            self.hud.setLevel(level)
        }
    }

    /// Pause / resume. Called from the capsule's ‖ button.
    ///
    /// `hud.setPaused` is the only call: it states 已暫停 where the window has
    /// room for it and puts the session's own state back on resume, so the
    /// controller no longer has to say the same thing to a second window.
    private func togglePause() {
        guard dictating || meeting else { return }
        paused.toggle()
        hud.setPaused(paused)
        // The session owns the audio, so pausing it is what actually stops the
        // input -- the microphone feed and the system-audio tap together, while
        // the ASR session stays open, so the transcript continues where it stopped
        // instead of starting a second one.
        if paused { session?.pause() } else { session?.resume() }
        if paused {
            // A paused recording is not a silent one: the warning must not fire
            // at the user for the state they asked for.
            lastSoundAt = Date()
        }
        ModelInstaller.log(paused ? "paused" : "resumed")
    }

    /// Warns when the microphone has carried nothing for a while.
    ///
    /// The failure that actually happens is not a denied permission -- that one
    /// shows a red label in the window -- but a muted input: the wrong device, a
    /// hardware mute key, or a headset that switched away. Recording keeps
    /// "working", so without this the first sign is an empty transcript.
    private func startSilenceWatch() {
        stopSilenceWatch()
        lastSoundAt = Date()
        silenceWarned = false
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.dictating || self.meeting else {
                self.stopSilenceWatch()
                return
            }
            // Paused is not silence, and a warning while paused would replace the
            // 已暫停 caption with a message about a mic the user already knows is
            // not being used.
            guard !self.paused else {
                self.lastSoundAt = Date()
                return
            }
            guard !self.silenceWarned,
                  Date().timeIntervalSince(self.lastSoundAt) >= Self.silenceWarnSeconds else {
                return
            }
            self.silenceWarned = true
            // One message, in the recording window: the notice carries the whole
            // sentence (and the fix), and the state pill cannot say more.
            self.hud.notice("沒有收到聲音 · 檢查麥克風或靜音鍵", seconds: 6)
            ModelInstaller.log("silence warning fired")
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - Dictation

    /// Transcribes a file through the same engine as a recording.
    ///
    /// The result is NOT pasted: an import is not dictation into a field, and
    /// pasting a ten-minute transcript into whatever happens to be focused would
    /// be destructive. It goes to the floating window's transcript and the
    /// clipboard, and the user decides where it lands.
    private func importAudioFile(_ url: URL) {
        guard !dictating, !meeting, !sessionStarting else {
            hud.flash("請先結束目前的錄音，再匯入音檔", seconds: 4)
            return
        }
        guard !audioImporter.isBusy else {
            hud.flash("已經在辨識另一個音檔", seconds: 3)
            return
        }
        guard ready else {
            hud.flash("模型還沒載入完成，請稍等", seconds: 3)
            return
        }
        ModelInstaller.log("import audio: \(url.lastPathComponent)")
        hud.allowShowingAgain()
        // `begin` shows the window itself and leaves the mode as a status line,
        // since an import is not a recording.
        hud.begin(title: url.lastPathComponent, status: "讀取音檔…")

        guard let engine else {
            hud.flash("模型還沒載入完成，請稍等", seconds: 3)
            return
        }
        audioImporter.importFile(
            at: url,
            engine: engine,
            onProgress: { [weak self] fraction in
                let percent = Int((fraction * 100).rounded())
                self?.hud.setStatus("辨識中… \(percent)%")
            },
            onStatus: { [weak self] status in
                self?.hud.setStatus(status)
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(imported):
                    self.hud.append(imported.segments, showSpeaker: false)
                    let minutes = Int(imported.duration) / 60
                    let seconds = Int(imported.duration) % 60
                    self.hud.finish(status: "辨識完成 · \(minutes):\(String(format: "%02d", seconds))")
                    self.mainWindow?.setTranscript(imported.text)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(imported.text, forType: .string)
                    ModelInstaller.log("import done: \(imported.text.count) chars, \(imported.segments.count) segments")
                    self.hud.flash("逐字稿已複製到剪貼簿（\(imported.text.count) 字）", seconds: 4)
                case let .failure(error):
                    self.hud.finish(status: "失敗")
                    ModelInstaller.log("import failed: \(error)")
                    self.hud.flash(error.localizedDescription, seconds: 6)
                }
                if ProcessInfo.processInfo.environment["OVC_SELFTEST_IMPORT"] != nil {
                    exit(0)
                }
            }
        )
    }

    private func startDictation() {
        startSession(meeting: false)
    }

    /// Opens one recording session: microphone in, transcript out.
    ///
    /// Dictation and a meeting are the same recording with three settings
    /// different: the window's title, whether the Mac's own audio is transcribed
    /// as 對方, and what happens to the transcript at the end (paste it, or save a
    /// summary). The capture, the segmentation, the ASR session and the closing
    /// utterance belong to the kit's `VoiceInputSession` -- the same code the
    /// command-line tool runs -- so there is nothing here to drift from it.
    private func startSession(meeting isMeeting: Bool) {
        // A session the user asked for may show the window again, even if the
        // previous one was dismissed with Escape.
        hud.allowShowingAgain()
        guard VoiceInputMicrophone.isAuthorized else {
            VoiceInputMicrophone.request { granted in
                DispatchQueue.main.async {
                    self.hud.flash(
                        granted
                            ? "已授權麥克風，再按一次\(isMeeting ? "開始會議" : "開始")"
                            : "麥克風權限被拒絕 (系統設定 > 隱私權 > 麥克風)", seconds: 4)
                }
            }
            return
        }
        guard !sessionStarting, let engine else { return }
        sessionStarting = true
        coreQueue.async {
            do {
                let session = try engine.makeSession(mode: isMeeting ? .meeting : .dictation)
                // Wired before `start()`: an utterance, a level sample or a
                // system-audio failure must have somewhere to land the moment the
                // session exists.
                self.wire(session, labelled: isMeeting)
                try session.start()
                DispatchQueue.main.async {
                    self.sessionStarting = false
                    self.session = session
                    self.dictating = !isMeeting
                    self.meeting = isMeeting
                    self.sessionSegments = []
                    self.sessionStartedAt = Date()
                    self.paused = false
                    self.meetingWarnings = []
                    self.setRecordingState()
                    self.hud.startRecording()
                    self.hud.begin(
                        title: isMeeting ? "會議逐字稿" : "聽寫",
                        status: isMeeting ? "錄音中…" : "辨識中…")
                    self.startSilenceWatch()
                    // The Mac's own audio is a meeting feature, switched on for
                    // THIS session rather than read from the config -- which is
                    // also what keeps the setting live: toggling the checkbox
                    // mid-meeting applies to the recording in progress instead of
                    // being silently deferred to the next one.
                    if isMeeting {
                        session.setSystemAudioEnabled(self.meetingSystemAudio)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.sessionStarting = false
                    self.hud.flash("\(error)", seconds: 5)
                }
            }
        }
    }

    /// Points one session's callbacks at the window.
    ///
    /// `labelled` is captured rather than read from `meeting`, because that flag
    /// is only set once the session is up, and a callback that arrived first would
    /// otherwise label the transcript from the previous recording's state.
    private func wire(_ session: VoiceInputSession, labelled: Bool) {
        session.onLevel = { [weak self] level in self?.noteLevel(level) }
        session.onPartial = { [weak self] text in
            self?.hud.setCount(text.count)
            self?.hud.setPartial(text)
        }
        session.onSegments = { [weak self] fresh in
            guard let self else { return }
            let segments = fresh.map(Self.transcriptSegment)
            self.sessionSegments.append(contentsOf: segments)
            self.hud.append(segments, showSpeaker: labelled)
        }
        // A refused or unsupported tap is never fatal: the recording continues on
        // the microphone, and the reason is remembered so the saved file can say
        // the other side of the call is missing.
        session.onSystemAudioFailure = { [weak self] reason in
            DispatchQueue.main.async { self?.reportSystemAudioFailure(reason) }
        }
    }

    private static func transcriptSegment(_ utterance: Utterance) -> TranscriptSegment {
        TranscriptSegment(
            index: utterance.index,
            speaker: utterance.source == .systemAudio ? .other : .me,
            start: utterance.start,
            end: utterance.end,
            text: utterance.text
        )
    }

    private func stopDictation() {
        dictating = false
        stopSilenceWatch()
        setRecordingState()
        hud.showStage("轉錄中…")
        endSession(status: "轉錄中…", labelled: false) { raw in
            self.deliver(raw)
        }
    }

    // MARK: - Meeting (long recording -> saved transcript + best-effort summary)

    private func startMeeting() {
        startSession(meeting: true)
    }

    /// Explains a system-audio failure: short line in the window, full text in the
    /// main window and the log, since only one of those is wide enough. The window
    /// line is also remembered so the meeting's own summary can say the other side
    /// of the call is missing.
    private func reportSystemAudioFailure(_ reason: String) {
        let message = "只錄麥克風：\(reason)"
        ModelInstaller.log("meeting system audio tap failed: \(reason)")
        if !meetingWarnings.contains(where: { $0.contains(reason) }) {
            meetingWarnings.append("系統音訊未錄到（\(reason)）")
        }
        hud.notice("系統音訊未錄到，只錄麥克風", seconds: 5)
        mainWindow?.setTranscript(message)
    }

    /// Applies a change to the "record the Mac's own audio" setting to the meeting
    /// that is already running, so the checkbox is not silently deferred to the
    /// next one. The session owns the tap, so this is one call rather than a
    /// second copy of the start/stop logic.
    private func applyMeetingSystemAudioChange(_ enabled: Bool) {
        guard meeting, let session else { return }
        session.setSystemAudioEnabled(enabled)
        ModelInstaller.log("meeting system audio set to \(enabled) for the running meeting")
    }

    private func stopMeeting() {
        meeting = false
        stopSilenceWatch()
        paused = false
        setRecordingState()
        hud.showStage("整理會議中…長會議需要幾分鐘")
        let eventTitle = CalendarNaming.recentlyEndedTitle()
        let startedAt = sessionStartedAt
        endSession(status: "錄音結束", labelled: true) { transcript in
            // Read on the main thread and handed to the worker as values: the
            // summary takes minutes, EventKit and the segment list are both
            // main-thread state, and reading them from the worker would be a race
            // that only shows up on a long meeting.
            let caveat = self.meetingCaveat
            let document = self.makeDocument()
            let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing was picked up: a saved file would be an empty record that
            // reads like a successful meeting.
            guard !body.isEmpty else {
                self.hud.flash("沒有錄到聲音，未儲存會議記錄", seconds: 5)
                self.mainWindow?.setTranscript("（這次會議沒有錄到聲音，未儲存檔案。）")
                self.meetingWarnings = []
                return
            }
            self.coreQueue.async {
                do {
                    let saved = try self.saveMeeting(
                        body, caveat: caveat, eventTitle: eventTitle, startedAt: startedAt)
                    let session = SessionExport(
                        document: document,
                        summary: saved.summary,
                        translation: nil,
                        caveat: caveat,
                        eventTitle: eventTitle
                    )
                    DispatchQueue.main.async {
                        self.lastSession = session
                        self.mainWindow?.setTranscript(body)
                        if caveat.isEmpty {
                            self.hud.flash("已儲存會議記錄：\(saved.url.lastPathComponent)", seconds: 4)
                        } else {
                            self.hud.flash("已儲存（部分內容未錄到，詳見紀錄）", seconds: 5)
                        }
                        self.meetingWarnings = []
                        self.autoExport(session)
                    }
                } catch {
                    DispatchQueue.main.async { self.hud.flash("\(error)", seconds: 5) }
                }
            }
        }
    }

    // MARK: - Ending a session

    /// Ends the running session and hands its raw transcript to `then`, on the
    /// main thread.
    ///
    /// `finish()` decodes the closing utterance itself, so the tail arrives with
    /// the result rather than through the live callbacks -- which is why the
    /// segments it returns are folded into the window here. `append` ignores
    /// indices it has already rendered, so the overlap is harmless.
    private func endSession(status: String, labelled: Bool, then: @escaping (String) -> Void) {
        let session = self.session
        self.session = nil
        coreQueue.async {
            let result = try? session?.finish()
            DispatchQueue.main.async {
                if let result {
                    let segments = result.segments.map(Self.transcriptSegment)
                    self.sessionSegments = segments
                    self.hud.append(segments, showSpeaker: labelled)
                }
                self.hud.finish(status: status)
                then(result?.raw ?? "")
            }
        }
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
    ///
    /// `eventTitle` is the calendar event the recording belongs to, when there is
    /// one: naming a file after the meeting is the point of asking for calendar
    /// access. `startedAt` is the session's start rather than "now" so the note
    /// and a later export of the same session produce the same name.
    @discardableResult
    private func saveMeeting(
        _ transcript: String,
        caveat: String,
        eventTitle: String?,
        startedAt: Date
    ) throws -> (url: URL, summary: String) {
        let dir = meetingsDirectory()
        // The recognizer and the model both drift into Simplified; the file is
        // for a Taiwanese reader, so normalize once here rather than in each pass.
        let traditional = VoiceText.toTraditional(transcript)
        // Summary is optional: a long transcript spawns several worker passes,
        // each of which reloads the model. Failure just means no shell to fill.
        // It is computed before the file is written because it is also the name
        // when no calendar event covers the recording.
        var summary = ""
        if !traditional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let engine,
           let answer = try? engine.summarize(traditional), !answer.isEmpty {
            summary = VoiceText.toTraditional(answer)
        }
        let base = Naming.stem(
            title: Naming.title(summary: summary, eventTitle: eventTitle, fallback: "會議紀錄"),
            date: startedAt
        )
        let txt = dir.appendingPathComponent("\(base).txt")
        try traditional.write(to: txt, atomically: true, encoding: .utf8)
        if !summary.isEmpty {
            let md = dir.appendingPathComponent("\(base).md")
            // A meeting recorded without the system-audio tap is missing the
            // other side of the call. Say so in the file: a reader cannot tell a
            // one-sided transcript from a quiet room.
            try? "\(caveat)\(summary)\n\n---\n\n\(traditional)\n"
                .write(to: md, atomically: true, encoding: .utf8)
        }
        return (txt, summary)
    }

    /// The caveat block for a one-sided recording, empty when nothing was wrong.
    private var meetingCaveat: String {
        meetingWarnings.isEmpty
            ? ""
            : "> 錄音提示：\(meetingWarnings.joined(separator: "；"))\n\n"
    }

    // MARK: - Export

    /// One finished recording, in the shape the exporter needs.
    ///
    /// The summary is markdown from the model, the caveat is ours, and the title
    /// is decided once at the end so the save panel, the auto-save and the file
    /// on disk all agree.
    private struct SessionExport {
        var document: TranscriptDocument
        var summary: String
        var translation: String?
        var caveat: String
        var eventTitle: String?
    }

    /// The document accumulated by the live poll.
    private func makeDocument(endedAt: Date = Date()) -> TranscriptDocument {
        TranscriptDocument(startedAt: sessionStartedAt, endedAt: endedAt, segments: sessionSegments)
    }

    private func bundle(for session: SessionExport) -> ExportBundle {
        ExportBundle(
            title: Naming.title(
                summary: session.summary,
                eventTitle: session.eventTitle
            ),
            transcript: session.document,
            summaryMarkdown: session.caveat + session.summary,
            translation: session.translation
        )
    }

    /// "匯出最近一次逐字稿…" from the app, or the menu-bar item.
    ///
    /// A folder is only used without asking when the user turned auto-save on;
    /// otherwise the save panel decides where the file goes.
    func exportLastSession() {
        guard let session = lastSession else {
            hud.flash("還沒有可匯出的逐字稿", seconds: 3)
            return
        }
        let bundle = self.bundle(for: session)

        if exportSettings.autoSave, exportSettings.folderURL != nil {
            write(bundle, to: nil)
            return
        }

        let format = exportSettings.format
        let panel = NSSavePanel()
        panel.title = "匯出逐字稿"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Naming.filename(
            title: bundle.title,
            date: session.document.startedAt,
            format: format
        )
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(bundle, to: url)
    }

    /// Writes one bundle, either to `url` or to the configured folder.
    private func write(_ bundle: ExportBundle, to url: URL?) {
        do {
            let target: URL
            if let url {
                try Exporter.data(bundle, as: exportSettings.format).write(to: url, options: .atomic)
                target = url
            } else {
                target = try Exporter.save(
                    bundle,
                    as: exportSettings.format,
                    settings: exportSettings
                )
            }
            hud.flash("已匯出：\(target.lastPathComponent)", seconds: 4)
            ModelInstaller.log("exported \(target.path)")
        } catch {
            hud.flash("匯出失敗：\(error)", seconds: 5)
        }
    }

    /// Auto-save after a recording, when the user asked for it.
    private func autoExport(_ session: SessionExport) {
        guard exportSettings.autoSave, exportSettings.folderURL != nil else { return }
        write(bundle(for: session), to: nil)
    }

    /// Keeps a finished dictation exportable, and auto-exports it if asked.
    ///
    /// A dictation has no summary section of its own: the polished line IS the
    /// content, and the verbatim segments are the transcript underneath it.
    private func rememberDictation(_ polished: String) {
        guard !isSelfTest else { return }
        let document = makeDocument()
        guard !document.segments.isEmpty || !polished.isEmpty else { return }
        let session = SessionExport(
            document: document,
            summary: polished,
            translation: nil,
            caveat: "",
            eventTitle: nil
        )
        lastSession = session
        autoExport(session)
    }

    // MARK: - Delivery

    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRawTranscript = trimmed
        // The words, not just the count: whether a bad result came from the
        // recogniser or from the cleanup pass is decided here, and until this line
        // existed the log could not answer it.
        ModelInstaller.log("asr: \(Self.preview(trimmed))")
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
    ///
    /// A dictation that is an instruction about the previous result is neither
    /// polished nor pasted as new text: it is applied to that result and replaces
    /// it. Catching it here means the wasted model pass is skipped too.
    private func present(_ trimmed: String) {
        // Normalise Chinese to Traditional up front: the speech recogniser emits
        // Simplified, and the LLM otherwise just mirrors whatever script it is
        // given.
        let text = VoiceText.toTraditional(trimmed)
        if let previous = lastDelivery, !previous.isEmpty, isVoiceEditInstruction(text) {
            applyEdit(text, to: previous)
            return
        }
        polishAndFinish(text)
    }

    /// The ordinary delivery: polish, then insert.
    ///
    /// Also the fallback for an edit that did not work out, which is what keeps a
    /// sentence the classifier merely suspected ("第一點要改善" said after a paste)
    /// from being swallowed: it arrives as text, late, instead of not at all.
    private func polishAndFinish(_ text: String) {
        guard polishEnabled else {
            finish(text)
            return
        }
        let explicit = translateTarget == "en" || translateTarget == "zh"
        hud.showStage(explicit ? "整理並翻譯中…" : "AI 整理中…")
        coreQueue.async {
            let polished = self.polish(text)
            DispatchQueue.main.async { self.finish(polished) }
        }
    }

    /// The 修改的提示詞 button: the same core call the spoken path makes, with the
    /// instruction typed and the region picked by hand.
    ///
    /// A separate entry point from `present(_:)` on purpose. The spoken path has
    /// to first decide whether a sentence IS an edit; this one was told so by the
    /// user pressing a button, so nothing is classified and nothing falls back to
    /// "paste it as a dictation". A failure here leaves the draft untouched and
    /// says so.
    private func applyManualEdit(_ instruction: String,
                                 region: PromptEditRegion,
                                 to draft: String,
                                 selection: Range<String.Index>?) {
        ModelInstaller.log("manual edit: region \(region.title), \(draft.count) chars")
        hud.showStage("套用修改中…")
        let config = passConfig()
        coreQueue.async {
            guard let edited = applyVoiceEdit(instruction, to: draft,
                                              region: region,
                                              selection: selection,
                                              config: config) else {
                DispatchQueue.main.async {
                    self.hud.flash("沒有改到任何字，原文沒有變動", seconds: 3)
                }
                return
            }
            DispatchQueue.main.async {
                self.mainWindow?.setTranscript(edited)
                self.recordHistory(edited)
                self.rememberDictation(edited)
                self.lastDelivery = edited
                self.hud.flash("已修改", seconds: 2)
            }
        }
    }

    /// Applies a spoken edit instruction to the text this app delivered last, and
    /// puts the result where that text is.
    ///
    /// Replacing means finding text that is no longer ours, so it goes through
    /// `TextInjector.replaceLastInsertion`: the exact string this app pasted,
    /// located at or before the caret, is selected and pasted over. When that
    /// cannot be proven -- a field that does not expose its text, an insertion the
    /// user has edited since -- the result stays on the clipboard with a line
    /// saying so. Appending an edit next to the text it corrects would be worse
    /// than not pasting it.
    private func applyEdit(_ instruction: String, to previous: String) {
        ModelInstaller.log("voice edit: instruction \(instruction.count) chars, text \(previous.count) chars")
        hud.showStage("套用編輯中…")
        let config = passConfig()
        coreQueue.async {
            guard let edited = applyVoiceEdit(instruction, to: previous, config: config) else {
                DispatchQueue.main.async {
                    // Neither the text nor the words are lost: the previous line is
                    // untouched, and what the user just said arrives as a normal
                    // dictation. A refusal costs a wrong paste, not a silent one.
                    self.hud.flash("沒有套用編輯，改為輸入原話", seconds: 3)
                    self.polishAndFinish(instruction)
                }
                return
            }
            DispatchQueue.main.async {
                // Shown and recorded either way: the line is the result of what
                // the user said, and they have to be able to read it even when it
                // cannot be pasted.
                self.mainWindow?.setTranscript(edited)
                self.recordHistory(edited)
                self.rememberDictation(edited)
                // An edit rewrites text the user can no longer see, so this is
                // exactly the case the "confirm first" setting exists for: the
                // edited line waits in the window, and pressing Enter pastes it
                // over the original. Without this the edit was the one delivery
                // path the setting did not cover.
                guard self.confirmBeforeInsert, !SelfTest.exitsWhenDone else {
                    self.commitEdit(edited, expected: previous)
                    return
                }
                self.hud.show(text: edited, mode: .edit) { [weak self] in
                    guard let self else { return }
                    let shown = self.hud.getDisplayedText().trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !shown.isEmpty else {
                        self.hud.show(text: "內容為空，已忽略")
                        return
                    }
                    // The window has to get out of the way first, or the paste
                    // lands in its own text field.
                    self.hud.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        self.commitEdit(shown, expected: previous)
                    }
                }
            }
        }
    }

    /// Puts an edited line where the text it corrects is.
    ///
    /// `previous` is the exact string this app pasted; the injector selects it in
    /// the focused field and pastes over it. When that cannot be proven the result
    /// stays on the clipboard -- `replaceLastInsertion` copies it before it looks
    /// for the text -- and the window says why.
    private func commitEdit(_ edited: String, expected previous: String) {
        switch TextInjector.replaceLastInsertion(expected: previous, with: edited) {
        case .pasted:
            // Only a proven replacement becomes the text a later instruction
            // edits: after a failure the field still holds `previous`, and
            // tracking the edited line would aim the next instruction at text that
            // is not there.
            lastDelivery = edited
            ModelInstaller.log("voice edit: replaced \(previous.count)->\(edited.count) chars")
            hud.showResult(edited)
        case let .needsPermission(reason), let .copiedOnly(reason):
            ModelInstaller.log("voice edit: result left on the clipboard (\(reason))")
            hud.show(text: "\(edited)\n(\(reason))", mode: .display)
        }
    }

    /// Translate the finished line when the user asked for it. It runs as its own
    /// model pass AFTER the refine pass: refine must not change the language,
    /// translation must, and asking one prompt to do both produced drafts that
    /// came back half-translated. In "auto" mode there is nothing to do here --
    /// the refine prompt is the one that decides the output language. A translation that fails, or that comes back as
    /// a note instead of a translation, falls back to the cleaned text so the
    /// dictation is never lost.
    /// Shows the result in the window and either inserts it immediately or (if
    /// the user asked to confirm first) shows an editable HUD and waits for Enter.
    private func finish(_ polished: String) {
        mainWindow?.setTranscript(polished)
        recordHistory(polished)
        rememberDictation(polished)
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

    /// The transcript window's 貼上: deliver what is on screen, exactly as the
    /// automatic path would.
    ///
    /// The window has to go first. It is the focused responder after a click on
    /// its button, so a synthesized Cmd+V would paste into our own text view --
    /// the same trap the edit card avoids by hiding before it commits.
    private func insertFromLiveWindow() {
        let text = hud.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hud.flash("沒有可貼上的文字")
            return
        }
        ModelInstaller.log("insert: from window, \(text.count) chars")
        hud.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.insertDirect(text)
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
        // Remembered before the paste, and in every outcome: a later edit
        // instruction is about this text, and the text counts as delivered even
        // when the user has to paste it themselves.
        lastDelivery = trimmed
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
        // The whole chain lives in VoiceInputKit so the app and the command-line
        // tool cannot drift apart: the sanity guard, the model fallback, the
        // translation pass and the spoken-edit prompt are one implementation there.
        let before = Date()
        let result = refineTranscript(raw, config: passConfig())
        // The engine owns the decision; the app only records what came out of it,
        // which is what the diagnosis in ova.log reads.
        let unchanged = result == VoiceText.toTraditional(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        ModelInstaller.log(
            "refine \(unchanged ? "kept raw" : "applied"): \(raw.count)->\(result.count) chars"
                + ", \(Int(Date().timeIntervalSince(before) * 1000)) ms"
        )
        return result
    }

    /// The kit's view of the app's settings, for a pass the app drives itself
    /// (refine, translate, spoken edit). The models directory is only used by the
    /// kit's own model-existence checks; `prepare()` already pointed the core at
    /// the real one, and the LLM choice reaches the worker through the process
    /// environment it inherits.
    private func passConfig() -> VoiceInputConfig {
        VoiceInputConfig(
            modelsDirectory: VoiceInputConfig.defaultModelsDirectory(),
            keywords: keywords.all,
            refineStages: Self.refineStagesOverride(),
            refineTone: refineTone,
            translateTarget: translateTarget,
            llmModel: LLMSelection.currentFileName,
            polishEnabled: polishEnabled
        )
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

    /// One-line excerpt for the log.
    ///
    /// The transcript itself is logged rather than only its length: "the output
    /// does not match what I said" is decided at exactly this point, and without
    /// the words there is no way to tell a recognition failure from a cleanup one
    /// after the fact.
    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 160 ? flat : String(flat.prefix(160)) + "…"
    }

    // MARK: - Test-only WAV path

    /// Feeds a WAV through the same pipeline a recording uses, then delivers the
    /// transcript. Enabled by the OVC_SELFTEST_WAV env var.
    ///
    /// The engine's config says `polishEnabled: false`, so a plain run stops at the
    /// transcript; `OVC_SELFTEST_POLISH` asks for the whole pipeline, which
    /// `deliver` then runs through `present()` like any dictation.
    private func runSelfTest(wavPath: String) {
        ModelInstaller.log("selftest: wav=\(wavPath)")
        hud.show(text: "自我測試中…")
        coreQueue.async {
            do {
                let dir = try Self.modelsDirectory { ModelInstaller.log($0) }
                let engine = try VoiceInputEngine(config: Self.engineConfig(modelsDir: dir))
                try engine.prepare()
                let result = try engine.transcribe(fileAt: URL(fileURLWithPath: wavPath))
                DispatchQueue.main.async {
                    self.engine = engine
                    self.deliver(result.raw)
                }
            } catch {
                ModelInstaller.log("selftest failed: \(error)")
                exit(5)
            }
        }
    }

    /// Runs a WAV through a MEETING session and checks that the cleanup chain
    /// does not run over it. Enabled by `OVC_SELFTEST_MEETING`.
    ///
    /// A meeting's transcript is a record of what was said, so it must not be
    /// rewritten by the dictation cleanup prompt. The check is that the model is
    /// not asked at all: a meeting used to pay for a full refinement and throw
    /// the answer away, which was both wrong (the transcript came back
    /// rewritten) and slow (minutes on a long meeting, and a second worker job
    /// contending with the summary).
    ///
    /// The proof is the WORKER TRACE: the app's own path is used, so if the
    /// cleanup ran, the worker would be invoked with the "refine" task. The
    /// trace is read at the end and the run fails when a refine shows up.
    ///
    /// `OVC_SELFTEST_MEETING_MODE=dictation` runs the CONTROL: the same
    /// harness with a dictation session, which must show a refine. Without it,
    /// a harness that never detects anything would pass every time -- the
    /// control is what makes the meeting result mean something.
    private func runMeetingSelfTest(wavPath: String) {
        let control = ProcessInfo.processInfo.environment["OVC_SELFTEST_MEETING_MODE"] == "dictation"
        let mode: VoiceInputSession.Mode = control ? .dictation : .meeting
        ModelInstaller.log("selftest meeting: wav=\(wavPath) mode=\(control ? "dictation" : "meeting")")
        hud.show(text: "自我測試中…")
        // The worker is a subprocess, so the only record of what it was asked
        // is a wrapper that writes the task down. Pointing the engine at one
        // makes the question answerable: did the cleanup run?
        let trace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ovc-worker-trace-\(UUID().uuidString).log")
        let worker = Self.installWorkerTrace(at: trace)
        setenv("OVC_LLM_WORKER", worker.path, 1)
        coreQueue.async {
            do {
                let dir = try Self.modelsDirectory { ModelInstaller.log($0) }
                // The cleanup has to be ON for this check to mean anything: a
                // dictation with polish off never asks the model, so the
                // control would pass for the wrong reason and the meeting
                // result would prove nothing.
                var config = Self.engineConfig(modelsDir: dir)
                config.polishEnabled = true
                let engine = try VoiceInputEngine(config: config)
                try engine.prepare()
                // The session is driven by the same audio the microphone would
                // feed, so the ASR path is the real one.
                let samples = try SelfTest.readWav(URL(fileURLWithPath: wavPath))
                let session = try engine.makeSession(mode: mode)
                try session.start(audioSource: { deliver in
                    // The WAV is fed in the chunks the microphone would deliver,
                    // so the ASR sees the same shape of audio it sees live.
                    for chunk in stride(from: 0, to: samples.count, by: 1600) {
                        deliver(Array(samples[chunk..<min(chunk + 1600, samples.count)]))
                    }
                })
                let result = try session.finish()
                let tasks = Self.workerTrace(at: trace)
                ModelInstaller.log("selftest meeting transcript: \(result.raw)")
                ModelInstaller.log("selftest meeting worker tasks: \(tasks)")
                DispatchQueue.main.async {
                    self.engine = engine
                    try? FileManager.default.removeItem(at: trace)
                    if control {
                        // The control has to FAIL without a refine, or the
                        // harness is not looking at anything.
                        if !tasks.contains("refine") {
                            ModelInstaller.log("selftest meeting CONTROL FAILED: a dictation did not run the cleanup")
                            exit(9)
                        }
                        ModelInstaller.log("selftest meeting CONTROL PASS")
                        exit(0)
                    }
                    if tasks.contains("refine") {
                        ModelInstaller.log("selftest meeting FAILED: the cleanup ran over a meeting transcript")
                        exit(6)
                    }
                    // The meeting text must be the transcript with the script
                    // normalised and nothing else: the recogniser emits
                    // Simplified, so the meeting text is Traditional while the
                    // raw text is not. What it must NOT be is a REWRITE -- the
                    // cleanup prompt condenses and reorders, and a meeting
                    // record that does that is wrong about what was said.
                    let expected = VoiceText.toTraditional(result.raw)
                    if result.refined != expected {
                        ModelInstaller.log("selftest meeting FAILED: the meeting text was rewritten, not normalised")
                        exit(7)
                    }
                    ModelInstaller.log("selftest meeting PASS")
                    exit(result.raw.isEmpty ? 8 : 0)
                }
            } catch {
                ModelInstaller.log("selftest meeting failed: \(error)")
                exit(5)
            }
        }
    }

    /// A wrapper around the real worker that writes down each task it is asked
    /// for, and runs the real thing.
    ///
    /// The task is the first argument, so the wrapper records it and hands every
    /// argument on unchanged. The real worker is found the same way the engine
    /// finds it -- beside the library, or through the environment -- so the
    /// wrapper does not change what actually runs.
    private static func installWorkerTrace(at trace: URL) -> URL {
        let worker = ProcessInfo.processInfo.environment["OVC_LLM_WORKER"]
            ?? (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Frameworks/ovc-llm-worker")
        let script = """
        #!/bin/sh
        echo "$1" >> "\(trace.path)"
        exec "\(worker)" "$@"
        """
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ovc-worker-trace-\(UUID().uuidString).sh")
        try? Data(script.utf8).write(to: path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// The tasks the worker was asked for, in order.
    private static func workerTrace(at trace: URL) -> [String] {
        guard let text = try? String(contentsOf: trace, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
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

let app = NSApplication.shared
// The Accessibility check needs a window that can TAKE THE FOCUS, and an
// accessory app cannot become the frontmost app -- so the posted Cmd+V would
// go to whatever else is in front and the field under test would never
// change. The policy is set here, before anything runs, rather than inside
// the check: by the time the check runs, the app has already been launched as
// an accessory and asking later is too late.
let isAXSelfTest = ProcessInfo.processInfo.environment["OVC_SELFTEST_AX"] != nil
app.setActivationPolicy(isAXSelfTest ? .regular : .accessory)

// A scripted check for the export path: four formats, one synthetic transcript,
// written to a temporary folder and read back. GUI-free on purpose, so it can run
// on a headless build without any permission prompts.
if let dir = ProcessInfo.processInfo.environment["OVC_SELFTEST_UI"] {
    let ids = (ProcessInfo.processInfo.environment["OVC_SELFTEST_UI_THEME"] ?? "paper")
        .split(separator: ",")
        .map(String.init)
    SelfTest.runWindowSelfTest(outDir: dir, themeIDs: ids)
}

if ProcessInfo.processInfo.environment["OVC_SELFTEST_EXPORT"] != nil {
    SelfTest.runExportSelfTest()
}

// Same idea for the palettes: five offscreen capsule renders plus the contrast
// maths a picture cannot show.
if ProcessInfo.processInfo.environment["OVC_SELFTEST_THEMES"] != nil {
    SelfTest.runThemeSelfTest()
}

// The Accessibility half of the spoken edit, against a real text field in a
// real window. This one needs a window server and Accessibility permission,
// which is why it runs in the app rather than in the test target.
if ProcessInfo.processInfo.environment["OVC_SELFTEST_AX"] != nil {
    DispatchQueue.main.async { AXSelfTest.run() }
}

let controller = AppController()
controller.start()
app.run()
