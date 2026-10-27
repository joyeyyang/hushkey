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

        bar.apply(
            phase: session.phase,
            text: text,
            needsSwitch: !(SharedStore.mode == .pip && SharedStore.pipAlive),
            paused: SharedStore.isPaused
        )

        if SharedStore.sharedContainer == nil {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        insertPending()
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
        bar.onCopy = { [weak self] in
            guard let self, !self.lastText.isEmpty else { return }
            UIPasteboard.general.string = self.lastText
            self.bar.showNotice("已複製 \(self.lastText.count) 字")
        }
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    // MARK: actions

    @objc private func openRecorder() {
        guard SharedStore.sharedContainer != nil else {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        // Mode 2: the app is already alive inside its PiP window, so asking it to
        // record needs no app switch -- and switching is the one thing this mode
        // exists to avoid. `pipAlive` is the guard: a mode that was chosen but is
        // not running would otherwise make this button do nothing at all, and a
        // killed app leaves its flags behind.
        if SharedStore.mode == .pip, SharedStore.pipAlive {
            SharedStore.requestRecording()
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
            self.bar.showNotice("App 沒有回應，請先切回「語音輸入」")
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

    private func openApp() {
        guard let url = URL(string: "ovc://record") else { return }
        extensionContext?.open(url) { [weak self] ok in
            guard !ok else { return }
            DispatchQueue.main.async {
                self?.bar.showNotice("請先從主畫面開啟「語音輸入」App")
            }
        }
    }
}
