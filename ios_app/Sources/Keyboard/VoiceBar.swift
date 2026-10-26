import UIKit

/// The keyboard's top row: a microphone, the words so far, copy, paste.
///
/// Deliberately not a capsule, and deliberately not SwiftUI: a keyboard
/// extension gets roughly 30-40 MB of usable memory before the system kills it
/// without an error, and the SwiftUI runtime spends a large part of that before
/// drawing anything. This is one label, three buttons and a spinner.
///
/// It mirrors the desktop HUD's controls one for one -- 錄音 / 停止 / 貼上 / 複製 --
/// because it is the same product, not a cut-down remote.
final class VoiceBar: UIView {
    /// Same phases as `SharedStore.Phase`, so one value drives both sides.
    private enum Look {
        case idle, recording, working, done, failed
    }

    var onMic: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)
    private let seal = UIColor(red: 0.76, green: 0.27, blue: 0.18, alpha: 1)
    private let dim = UIColor(red: 0.58, green: 0.55, blue: 0.51, alpha: 1)

    private let micButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var look: Look = .idle
    private var hasText = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        apply(phase: .idle, text: "", needsSwitch: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: build

    private func build() {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        micButton.layer.cornerRadius = 18
        micButton.layer.borderWidth = 1
        micButton.layer.borderColor = seal.cgColor
        micButton.tintColor = seal
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        micButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        micButton.accessibilityLabel = "語音輸入"

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = seal
        micButton.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
        ])

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = dim
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.numberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(copyButton, symbol: "doc.on.doc", label: "複製")
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        configure(pasteButton, symbol: "text.insert", label: "插入")
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        [micButton, statusLabel, copyButton, pasteButton].forEach(row.addArrangedSubview)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = ink
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    // MARK: state

    /// - Parameter needsSwitch: true when the app is not already resident, i.e.
    ///   tapping the microphone will open it. Drawn as an outlined microphone, the
    ///   same signal the reference product uses, so the user knows before tapping.
    func apply(phase: SharedStore.Phase, text: String, needsSwitch: Bool) {
        switch phase {
        case .recording:
            look = .recording
            statusLabel.text = text.isEmpty ? "錄音中…" : text
            statusLabel.textColor = ink
        case .transcribing:
            look = .working
            statusLabel.text = text.isEmpty ? "辨識中…" : text
            statusLabel.textColor = ink.withAlphaComponent(0.8)
        case .refining:
            look = .working
            statusLabel.text = text.isEmpty ? "整理中…" : text
            statusLabel.textColor = ink.withAlphaComponent(0.8)
        case .done:
            look = .done
            statusLabel.text = text.isEmpty ? "已插入" : text
            statusLabel.textColor = ink
        case .failed:
            look = .failed
            statusLabel.text = text.isEmpty ? "發生錯誤" : text
            statusLabel.textColor = seal
        case .idle:
            look = .idle
            statusLabel.text = text.isEmpty ? "按麥克風開始說話" : text
            statusLabel.textColor = text.isEmpty ? dim : ink
        }
        hasText = !text.isEmpty
        paint(needsSwitch: needsSwitch)
    }

    /// A one-line message that is not part of the pipeline (permission missing,
    /// app not installed). Keeps the microphone usable.
    func showNotice(_ message: String) {
        statusLabel.text = message
        statusLabel.textColor = seal
        look = .failed
        paint(needsSwitch: true)
    }

    private func paint(needsSwitch: Bool) {
        let working = look == .working
        let recording = look == .recording

        let symbol: String
        if recording {
            symbol = "stop.fill"
        } else if needsSwitch {
            symbol = "mic"
        } else {
            symbol = "mic.fill"
        }
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        micButton.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)

        micButton.backgroundColor = recording ? seal : .clear
        micButton.tintColor = recording ? .white : (look == .failed ? dim : seal)
        micButton.layer.borderColor = (look == .failed ? dim : seal).cgColor
        micButton.isEnabled = !working
        if working { spinner.startAnimating() } else { spinner.stopAnimating() }

        let textAlpha: CGFloat = hasText ? 1 : 0.35
        copyButton.isEnabled = hasText
        pasteButton.isEnabled = hasText
        copyButton.alpha = textAlpha
        pasteButton.alpha = textAlpha
    }

    // MARK: actions

    @objc private func micTapped() { onMic?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func pasteTapped() { onPaste?() }
}
