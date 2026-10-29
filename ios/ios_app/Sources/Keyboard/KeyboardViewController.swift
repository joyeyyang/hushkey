import UIKit

/// The voice-input keyboard.
///
/// It is a keyboard *category* in the same sense as Zhuyin or English: the user
/// adds it under 設定 › 一般 › 鍵盤, and switches with 🌐. The system keyboards
/// are untouched.
///
/// It cannot record. iOS refuses microphone access inside an app extension in
/// CoreMedia, before any permission prompt, and no entitlement lifts it -- so the
/// microphone belongs to the containing app, and this extension's job is the three
/// things it *can* do: show the session's phase, type the result at the cursor,
/// and hand the text to the clipboard.
///
/// It also has no letter keys. A QWERTY row under the microphone made this a worse
/// English keyboard with a recording button attached; the user's own keyboard is
/// one globe tap away, which is what the globe button is for.
final class KeyboardViewController: UIInputViewController {

    private var bar: VoiceBar!
    private var refreshTimer: Timer?
    /// The last text this keyboard saw, so ⧉ still works after it was inserted.
    private var lastText = ""
    /// The sequence of the 修改的提示詞 this keyboard is waiting for.
    ///
    /// Only one at a time: the panel has one 套用 button and the app runs one
    /// generation on one queue, so a second request would queue behind the first
    /// and the user would be looking at an answer to the older one.
    private var editSeq: Int?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.10, green: 0.09, blue: 0.085, alpha: 1)
        build()
        SharedStore.observe { [weak self] in self?.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        startPolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The app may have finished while this extension was off screen; the text
        // is typed here, which is the moment the user asked for.
        insertPending()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: session

    private func startPolling() {
        refreshTimer?.invalidate()
        // Cheap: one defaults read. The Darwin notification is the fast path; this
        // is the one that survives a missed notification.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let session = SharedStore.current()
        let text: String
        switch session.phase {
        case .recording:
            text = session.partial
        case .done:
            text = session.text ?? lastText
        case .transcribing, .refining, .failed:
            text = session.detail ?? session.partial
        case .idle:
            text = SharedStore.sharedContainer == nil ? "" : lastText
        }

        if let ready = session.text, !ready.isEmpty { lastText = ready }

        // The register is the app's setting; the bar only draws it. Read back on
        // every tick so a change made in Settings shows up here, and so the two
        // processes cannot end up showing different modes.
        bar.setTone(SharedStore.refineTone)

        // The panel's status line is the one the user is acting on, so a phase
        // update must not paint over "修改中…" or "請先開啟 Hushkey 一次".
        if editSeq == nil {
            bar.apply(
                phase: session.phase,
                text: text,
                needsSwitch: !(SharedStore.mode == .pip && SharedStore.pipAlive),
                paused: SharedStore.isPaused
            )
        }

        if SharedStore.sharedContainer == nil {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        insertPending()
        checkEditResult()
        applyPendingEditResult()
    }

    /// Types the app's result exactly once, at the cursor.
    ///
    /// Only while the keyboard is on screen: `textDocumentProxy` is meaningless
    /// when it is not, and `insertText` reports nothing, so consuming the
    /// obligation off screen would mark the sentence typed while it went
    /// nowhere. The Darwin notification refreshes off screen too, which is how
    /// this used to happen.
    private func insertPending() {
        guard view.window != nil else { return }
        guard let pending = SharedStore.pending() else { return }
        // 用說的: this dictation is the 修改的提示詞, not text for the cursor. It
        // goes into the panel, where the user can fix it before 套用.
        if SharedStore.instructionDictation {
            SharedStore.instructionDictation = false
            SharedStore.markConsumed(pending.seq)
            let draft = SharedStore.instructionDictationDraft
            SharedStore.instructionDictationDraft = ""
            if !draft.isEmpty { lastText = draft }
            openInstructionPanel(prefill: pending.text)
            return
        }
        // A dictation that reads as an instruction ("把第二點改成四點") is not
        // text for the cursor. It opens the 修改的提示詞 panel with those words in
        // it, so the user confirms with 套用 and nothing is rewritten behind their
        // back. The predicate is a pure function (ported from the Mac's
        // `VoiceEdit.swift`): no model, so the decision costs nothing here.
        if !lastText.isEmpty, isVoiceEditInstruction(pending.text) {
            SharedStore.markConsumed(pending.seq)
            openInstructionPanel(prefill: pending.text)
            return
        }
        textDocumentProxy.insertText(pending.text)
        SharedStore.markConsumed(pending.seq)
        lastText = pending.text
        bar.apply(phase: .done, text: "已插入 \(pending.text.count) 字",
                  needsSwitch: true, paused: false)
    }

    // MARK: ui

    private func build() {
        bar = VoiceBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onMic = { [weak self] in self?.openRecorder() }
        bar.onPause = { [weak self] in self?.togglePause() }
        bar.onNext = { [weak self] in self?.advanceToNextInputMode() }
        bar.onEdit = { [weak self] in self?.toggleEditPanel() }
        bar.onVoiceInstruction = { [weak self] in self?.speakInstruction() }
        bar.onEditApply = { [weak self] instruction, region, line in
            self?.applyEdit(instruction, region: region, line: line)
        }
        bar.onToneChange = { SharedStore.refineTone = $0 }
        bar.onOpenApp = { [weak self] in self?.openAppForEdit() }
        bar.onCopy = { [weak self] in
            guard let self, !self.lastText.isEmpty else { return }
            UIPasteboard.general.string = self.lastText
            self.bar.showNotice("已複製 \(self.lastText.count) 字")
        }
        view.addSubview(bar)

        // Pinned on all four sides, bottom included: the extension's height is
        // whatever its content asks for, and a bar pinned only at the top left the
        // system's default keyboard height (a QWERTY-sized 216 pt) with the bar
        // floating in the top third of it. The bar owns its own 126 pt.
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: 修改的提示詞

    private func toggleEditPanel() {
        if bar.isEditing {
            bar.hideEditPanel()
            return
        }
        guard SharedStore.sharedContainer != nil else {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        guard !lastText.isEmpty else {
            bar.showNotice("先插入一段文字，再修改它。")
            return
        }
        guard SharedStore.current().phase != .recording else {
            bar.showNotice("錄音中不能修改，先停下來。")
            return
        }
        openInstructionPanel(prefill: "")
    }

    /// Opens the panel with the draft's lines filled in, so 第 N 行 can name one.
    private func openInstructionPanel(prefill: String) {
        bar.setDraftLines(VoiceBar.lines(of: lastText))
        bar.showEditPanel(prefill: prefill)
    }

    /// 用說的: the instruction is dictated like any other sentence, but its
    /// result goes into the panel instead of the cursor.
    ///
    /// It exists because a keyboard extension cannot present a system keyboard --
    /// so on a phone there is no way to TYPE into the panel's field. Speaking the
    /// instruction is the route that works there; the field stays for a hardware
    /// keyboard, and for fixing a word the recogniser got wrong.
    private func speakInstruction() {
        guard SharedStore.sharedContainer != nil else {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        SharedStore.instructionDictationDraft = lastText
        SharedStore.instructionDictation = true
        SharedStore.requestRecording()
        if SharedStore.mode == .pip, SharedStore.pipAlive {
            bar.showWorking("說出要怎麼改…")
            return
        }
        openApp()
    }

    /// 套用: one request to the app, then wait for its acknowledgement and its
    /// answer.
    ///
    /// The two waits are separate because they mean different things. No
    /// acknowledgement within a beat means the app is not running -- a 20-second
    /// edit is not evidence of that, so a single timeout would either give up on
    /// a working edit or tell the user to open an app that is already open.
    private func applyEdit(_ instruction: String, region: String, line: Int) {
        let draft = lastText
        guard !draft.isEmpty else {
            bar.showNotice("先插入一段文字，再修改它。")
            return
        }
        guard editSeq == nil else {
            bar.showWorking("還在改上一次的，請等一下。")
            return
        }
        // 選取範圍 without a selection is a refusal, not a silent fallback to the
        // whole draft: "只改我選的那段" must never rewrite the rest.
        var selection: String?
        if region == "selection" {
            let selected = textDocumentProxy.selectedText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !selected.isEmpty else {
                bar.showNotice("先在文字上選取要改的那一段。")
                return
            }
            guard draft.contains(selected) else {
                bar.showNotice("選取範圍不在剛才插入的文字裡。")
                return
            }
            selection = selected
        }
        let seq = SharedStore.requestEdit(
            draft: draft, instruction: instruction,
            region: region, line: line, selection: selection
        )
        editSeq = seq
        bar.showWorking("修改中…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.editSeq == seq else { return }
            guard SharedStore.editAckedSeq < seq else { return }
            self.bar.showAppNeeded()
        }
        // The same bound the app's own panel uses. A phone loads the model per
        // call, so this is generous on purpose: giving up on a working edit and
        // leaving the text unchanged is worse than a long wait the user can see.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.editSeq == seq else { return }
            self.editSeq = nil
            self.bar.showNotice("修改沒有回應，原文沒有變動。")
        }
    }

    private func checkEditResult() {
        guard let seq = editSeq, let result = SharedStore.editResult(for: seq) else { return }
        editSeq = nil
        SharedStore.markEditApplied(seq)
        guard let text = result.text, !text.isEmpty else {
            bar.showNotice(result.error ?? "修改失敗，原文沒有變動。")
            return
        }
        replaceDraft(with: text)
    }

    /// The answer to a request this process did not make.
    ///
    /// Mode 1 opens the app to record the instruction, which destroys the
    /// keyboard; the answer therefore arrives in a new process. The group keeps
    /// it until it has been applied once, which is what this reads.
    private func applyPendingEditResult() {
        guard editSeq == nil, let pending = SharedStore.unappliedEditResult() else { return }
        SharedStore.markEditApplied(pending.result.seq)
        guard let text = pending.result.text, !text.isEmpty else {
            bar.showNotice(pending.result.error ?? "修改失敗，原文沒有變動。")
            return
        }
        // The draft is the one the request carried: this process never had it.
        lastText = pending.draft
        replaceDraft(with: text)
    }

    /// Puts the edited text where the draft was.
    ///
    /// The only text this keyboard can locate exactly is the sentence it typed
    /// itself, and only while the cursor is still right behind it. If the user
    /// has typed or moved since, the draft is not where it was -- so the answer
    /// goes to the clipboard instead of deleting whatever happens to be there.
    private func replaceDraft(with text: String) {
        let draft = lastText
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard !draft.isEmpty, before.hasSuffix(draft) else {
            UIPasteboard.general.string = text
            lastText = text
            bar.hideEditPanel()
            bar.showNotice("游標不在原文後面，已複製修改後的文字。")
            return
        }
        for _ in 0..<draft.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(text)
        lastText = text
        bar.hideEditPanel()
        bar.apply(phase: .done, text: "已換成 \(text.count) 字", needsSwitch: true, paused: false)
    }

    /// The app is not running, so the request has nowhere to run. Opening it is
    /// the user's decision, not something a 套用 tap does silently -- the request
    /// is already in the group, so any way of getting there works, and the app
    /// finds it when it becomes active.
    private func openAppForEdit() {
        guard let url = URL(string: "ovc://edit") else { return }
        extensionContext?.open(url) { [weak self] ok in
            guard !ok else { return }
            DispatchQueue.main.async {
                self?.bar.showNotice("已送出修改請求，切回 Hushkey 就會處理。")
            }
        }
    }

    // MARK: actions

    @objc private func openRecorder() {
        guard SharedStore.sharedContainer != nil else {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        // Written down before anything is attempted, on both paths. `open()` can be
        // refused (iOS declines it while the containing app is already resident) and
        // a Darwin notification only reaches a process that is listening, so the
        // request is left where the app cannot miss it -- it is how a tap that
        // arrives while the app is backgrounded still turns into a recording.
        SharedStore.requestRecording()

        // Mode 2: the app is already alive inside its PiP window, so asking it to
        // record needs no app switch -- and switching is the one thing this mode
        // exists to avoid. `pipAlive` is the guard: a mode that was chosen but is
        // not running would otherwise make this button do nothing at all, and a
        // killed app leaves its flags behind.
        if SharedStore.mode == .pip, SharedStore.pipAlive {
            bar.showNotice("錄音中…")
            confirmOrFallBack()
            return
        }
        openApp()
    }

    /// Pause or resume, as a message to the app.
    ///
    /// The button only works while a recording exists, and the app is the only side
    /// that knows whether it does -- so this asks and then checks, rather than
    /// painting the new state optimistically off its own guess.
    private func togglePause() {
        let paused = SharedStore.isPaused
        if paused {
            SharedStore.requestResume()
        } else {
            SharedStore.requestPause()
        }
        bar.showNotice(paused ? "繼續中…" : "暫停中…")
        // The app may be suspended (Mode 1 records from the background). If the
        // state did not move within a beat, say so instead of leaving a button that
        // looks like it worked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            guard SharedStore.isPaused == !paused else { return }
            self.bar.showNotice("App 沒有回應，請先切回「Hushkey」")
        }
    }

    /// A Darwin notification has no acknowledgement, so the request is checked:
    /// if the app did not move to `.recording` within a beat, it is not listening
    /// and the tap falls back to opening it. Otherwise a live-but-stuck app makes
    /// the microphone a button that shows "錄音中…" and records nothing.
    private func confirmOrFallBack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard SharedStore.current().phase != .recording else { return }
            SharedStore.pipLive = false
            self.bar.showNotice("小窗沒有回應，改為開啟 App")
            self.openApp()
        }
    }

    /// Asks iOS to bring the app forward.
    ///
    /// `open()`'s completion is NOT a statement about whether the app is running,
    /// which is what this used to assume: iOS refuses the open when the containing
    /// app is already resident, and the user was then told to go and open an app
    /// that was already open -- with the tap thrown away. The refusal is real
    /// information about the *switch*, not about the app, so that is all it is used
    /// for now.
    ///
    /// The request itself was written to the group before this call, so going back
    /// to the app by any means at all -- the app switcher, the home screen, the
    /// icon -- is enough: the app finds the request when it becomes active and
    /// starts recording. The notice says that instead of asking for something the
    /// user may have already done.
    private func openApp() {
        guard let url = URL(string: "ovc://record") else { return }
        extensionContext?.open(url) { [weak self] ok in
            guard !ok else { return }
            DispatchQueue.main.async {
                self?.bar.showNotice("已送出錄音請求，切回 Hushkey 就會開始")
            }
        }
    }
}
