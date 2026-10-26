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
final class KeyboardViewController: UIInputViewController {
    private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    private var bar: VoiceBar!
    private var shifted = false
    private var refreshTimer: Timer?
    /// The last text this keyboard saw, so ⧉ still works after it was inserted.
    private var lastText = ""

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)

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

        bar.apply(phase: session.phase, text: text, needsSwitch: true)

        if SharedStore.sharedContainer == nil {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        insertPending()
    }

    /// Types the app's result exactly once, at the cursor.
    private func insertPending() {
        guard let text = SharedStore.pendingText() else { return }
        textDocumentProxy.insertText(text)
        SharedStore.markConsumed()
        lastText = text
        bar.apply(phase: .done, text: "已插入 \(text.count) 字", needsSwitch: true)
    }

    // MARK: ui

    private func build() {
        bar = VoiceBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onMic = { [weak self] in self?.openRecorder() }
        bar.onCopy = { [weak self] in
            guard let self, !self.lastText.isEmpty else { return }
            UIPasteboard.general.string = self.lastText
            self.bar.showNotice("已複製 \(self.lastText.count) 字")
        }
        bar.onPaste = { [weak self] in
            guard let self, !self.lastText.isEmpty else { return }
            self.textDocumentProxy.insertText(self.lastText)
        }
        view.addSubview(bar)

        let keys = buildKeys()
        view.addSubview(keys)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),

            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            keys.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            keys.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    private func buildKeys() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in rows {
            let line = UIStackView()
            line.axis = .horizontal
            line.spacing = 5
            line.distribution = .fillEqually
            for ch in row {
                line.addArrangedSubview(key(String(ch), action: #selector(typeKey(_:))))
            }
            if row == rows[2] {
                line.insertArrangedSubview(key("⌫", action: #selector(backspace)), at: 0)
                line.insertArrangedSubview(key("⇧", action: #selector(shiftKey)), at: 0)
            }
            stack.addArrangedSubview(line)
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 5
        bottom.distribution = .fillEqually
        bottom.addArrangedSubview(key("🌐", action: #selector(nextKeyboard)))
        bottom.addArrangedSubview(key("空白", action: #selector(spaceKey)))
        bottom.addArrangedSubview(key("換行", action: #selector(returnKey)))
        stack.addArrangedSubview(bottom)

        return stack
    }

    private func key(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(ink, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        button.layer.cornerRadius = 6
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: actions

    @objc private func openRecorder() {
        guard SharedStore.sharedContainer != nil else {
            bar.showNotice("請到 設定 › 一般 › 鍵盤 開啟「允許完全取用」")
            return
        }
        guard let url = URL(string: "ovc://record") else { return }
        extensionContext?.open(url) { [weak self] ok in
            guard !ok else { return }
            DispatchQueue.main.async {
                self?.bar.showNotice("請先從主畫面開啟「語音輸入」App")
            }
        }
    }

    @objc private func typeKey(_ sender: UIButton) {
        guard var text = sender.title(for: .normal) else { return }
        if shifted { text = text.uppercased() }
        textDocumentProxy.insertText(text)
        if shifted { setShift(false) }
    }

    @objc private func shiftKey() { setShift(!shifted) }

    private func setShift(_ on: Bool) {
        shifted = on
        for case let line as UIStackView in view.subviews.compactMap({ $0 as? UIStackView }) {
            for case let button as UIButton in line.arrangedSubviews {
                guard let t = button.title(for: .normal), t.count == 1, t != "⇧" else { continue }
                button.setTitle(on ? t.uppercased() : t.lowercased(), for: .normal)
            }
        }
    }

    @objc private func backspace() { textDocumentProxy.deleteBackward() }
    @objc private func spaceKey() { textDocumentProxy.insertText(" ") }
    @objc private func returnKey() { textDocumentProxy.insertText("\n") }
    @objc private func nextKeyboard() { advanceToNextInputMode() }
}
