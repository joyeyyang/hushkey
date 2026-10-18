import AppKit
import Foundation

/// Coordinates setup -> hotkey -> mic -> core ASR -> LLM polish -> text injection.
/// Core and audio calls run on coreQueue; all UI updates run on the main thread.
final class AppController {
    private let keywords = Keywords()
    private let hud = HUDWindow()
    private var statusItem: StatusItem?
    private var mainWindow: MainWindow?
    private var capture: AudioCapture?
    private var hotkey: Hotkey?
    private var dictating = false
    private var meeting = false
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
        let window = MainWindow(keywords: keywords)
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
        if !ready { pendingAction = .dictation; ensureModelsLoaded(); return }
        if dictating { stopDictation() } else { startDictation() }
    }

    func toggleMeeting() {
        if !ready { pendingAction = .meeting; ensureModelsLoaded(); return }
        if meeting { stopMeeting() } else { startMeeting() }
    }

    func openMeetingsFolder() {
        NSWorkspace.shared.open(meetingsDirectory())
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
                try Core.initialize(modelsDir: dir.path)
                try Core.loadASR()
                ModelInstaller.log("core ready: \(dir.path)")
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
        guard AudioCapture.microphoneAuthorized() else {
            AudioCapture.requestMicrophone { granted in
                DispatchQueue.main.async {
                    self.hud.flash(granted ? "已授權麥克風，再按一次開始" : "麥克風權限被拒絕 (系統設定 > 隱私權 > 麥克風)", seconds: 4)
                }
            }
            return
        }
        coreQueue.async {
            do { try Core.startASR() } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
                return
            }
            DispatchQueue.main.async {
                self.dictating = true
                self.setRecordingState()
                self.hud.startRecording()
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
        coreQueue.async {
            do { try Core.startASR() } catch {
                DispatchQueue.main.async { self.hud.show(text: "\(error)") }
                return
            }
            DispatchQueue.main.async {
                self.meeting = true
                self.dictating = false
                self.setRecordingState()
                self.hud.startRecording()
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
                }
            }
        }
    }

    private func stopMeeting() {
        capture?.stop()
        capture = nil
        meeting = false
        stopLiveCount()
        setRecordingState()
        hud.show(text: "整理會議中…")
        coreQueue.async {
            do {
                let transcript = try Core.stopASR()
                let saved = try self.saveMeeting(transcript)
                DispatchQueue.main.async {
                    self.mainWindow?.setTranscript(transcript)
                    self.hud.flash("已儲存會議記錄：\(saved.lastPathComponent)", seconds: 4)
                }
            } catch {
                DispatchQueue.main.async { self.hud.flash("\(error)", seconds: 5) }
            }
        }
    }

    // MARK: - Live capsule readout

    /// Polls a live transcript preview so the capsule can show a real character
    /// count while the user is still speaking. The preview re-decodes whatever
    /// audio is buffered, so it is polled slowly, never overlapped, and switched
    /// off once a recording gets long enough for that to cost real time.
    private func startLiveCount() {
        stopLiveCount()
        recordingStart = Date()
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.recordingStart) > 60 { self.stopLiveCount(); return }
            if self.peeking { return }
            self.peeking = true
            self.coreQueue.async {
                let text = (try? Core.peekASR()) ?? ""
                DispatchQueue.main.async {
                    self.peeking = false
                    self.hud.setCount(text.count)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveCountTimer = timer
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
        let txt = dir.appendingPathComponent("meeting-\(stamp).txt")
        try transcript.write(to: txt, atomically: true, encoding: .utf8)
        // Summary is optional: a long transcript spawns several worker passes,
        // each of which reloads the model. Failure just means no .md file.
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let summary = try? Core.summarize(transcript), !summary.isEmpty {
            let md = dir.appendingPathComponent("meeting-\(stamp).md")
            try? "\(summary)\n\n---\n\n\(transcript)\n".write(to: md, atomically: true, encoding: .utf8)
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
        hud.show(text: "AI 整理中…")
        coreQueue.async {
            let polished = self.polish(text)
            DispatchQueue.main.async { self.finish(polished) }
        }
    }

    /// Shows the result in the window and either inserts it immediately or (if
    /// the user asked to confirm first) shows an editable HUD and waits for Enter.
    private func finish(_ polished: String) {
        mainWindow?.setTranscript(polished)
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

    /// Editable-HUD path: hide the HUD first so the paste does not land in our
    /// own text field (which would duplicate the text).
    private func insertAfterHidingHUD(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        for label in ["整理：", "整理:", "潤飾：", "潤飾:", "草稿：", "草稿:", "輸出：", "Output:", "Polished:"] {
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
