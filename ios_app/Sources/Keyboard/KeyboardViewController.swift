import UIKit

/// A keyboard that types and, when asked, hands the microphone to the app.
///
/// The extension cannot run the recogniser itself (keyboard memory budgets are
/// tens of megabytes), so 麥克風 opens the app through its URL scheme. The app
/// records, transcribes and leaves the text in the App Group; this keyboard
/// types whatever arrived the next time it is shown.
final class KeyboardViewController: UIInputViewController {
    private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private var statusLabel: UILabel!
    private var shifted = false

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)
    private let seal = UIColor(red: 0.76, green: 0.27, blue: 0.18, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.10, green: 0.09, blue: 0.085, alpha: 1)
        buildBar()
        buildKeys()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
        insertPending()
    }

    // MARK: handoff

    private func refreshStatus() {
        if let pending = SharedStore.pending() {
            statusLabel.text = "上次：\(pending.text.prefix(18))"
            statusLabel.textColor = ink
        } else {
            statusLabel.text = "按麥克風開始說話"
            statusLabel.textColor = ink.withAlphaComponent(0.5)
        }
    }

    /// Types the text the app left for us, exactly once.
    private func insertPending() {
        guard let pending = SharedStore.pending() else { return }
        textDocumentProxy.insertText(pending.text)
        SharedStore.markConsumed(pending)
        statusLabel.text = "已插入 \(pending.text.count) 個字"
    }

    // MARK: ui

    private func buildBar() {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let mic = UIButton(type: .system)
        mic.setTitle("🎙 說話", for: .normal)
        mic.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        mic.setTitleColor(.white, for: .normal)
        mic.backgroundColor = seal
        mic.layer.cornerRadius = 9
        mic.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        mic.addTarget(self, action: #selector(openRecorder), for: .touchUpInside)

        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.addArrangedSubview(mic)
        bar.addArrangedSubview(statusLabel)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            bar.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func buildKeys() {
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
        // 貼上上次 is the manual escape hatch for a handoff the auto-insert missed.
        bottom.addArrangedSubview(key("貼上", action: #selector(pasteLast)))
        stack.addArrangedSubview(bottom)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 50),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
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
        guard let url = URL(string: "ovc://record") else { return }
        extensionContext?.open(url) { [weak self] ok in
            guard !ok else { return }
            DispatchQueue.main.async {
                self?.statusLabel.text = "請先從主畫面開啟「語音輸入」App"
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

    @objc private func pasteLast() {
        guard let h = SharedStore.latest() else {
            statusLabel.text = "還沒有聽寫結果"
            return
        }
        textDocumentProxy.insertText(h.text)
        SharedStore.markConsumed(h)
        statusLabel.text = "已插入 \(h.text.count) 個字"
    }
}
