import UIKit

/// The whole keyboard: a microphone, a pause button, copy, and the words so far.
///
/// There is deliberately **no letter keyboard**. This extension exists for one
/// thing -- turning speech into text at the cursor -- and a QWERTY row under it
/// made it a worse English keyboard with a microphone attached. Someone who wants
/// to type switches back to their own keyboard with the globe on the left; that
/// button is not decoration, it is the only way out, so it stays even though
/// nothing else does.
///
/// Deliberately not SwiftUI, and deliberately not a capsule: a keyboard extension
/// gets roughly 30-40 MB of usable memory before the system kills it without an
/// error, and the SwiftUI runtime spends a large part of that before drawing
/// anything. This is one label and four buttons.
final class VoiceBar: UIView {
    /// Same phases as `SharedStore.Phase`, so one value drives both sides.
    private enum Look {
        case idle, recording, working, done, failed
    }

    var onMic: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Pause or resume, whichever the current state calls for.
    var onPause: (() -> Void)?
    /// Advance to the next input mode -- the only way to reach the user's own
    /// keyboard from here.
    var onNext: (() -> Void)?

    /// How tall the keyboard is. Everything above this number is spent on the
    /// transcript, which is the part worth reading.
    static let height: CGFloat = 126

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)
    private let seal = UIColor(red: 0.76, green: 0.27, blue: 0.18, alpha: 1)
    private let dim = UIColor(red: 0.58, green: 0.55, blue: 0.51, alpha: 1)

    private let micButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var look: Look = .idle
    private var paused = false
    private var hasText = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        apply(phase: .idle, text: "", needsSwitch: true, paused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: build

    private func build() {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The transcript, two lines of it. The keyboard is where the user is
        // already looking, so this is the only live view of what was heard that
        // does not require leaving the app they are typing in.
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = dim
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingHead
        column.addArrangedSubview(statusLabel)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        column.addArrangedSubview(row)

        configure(globeButton, symbol: "globe", label: "下一個鍵盤", size: 18)
        globeButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        row.addArrangedSubview(globeButton)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        configure(copyButton, symbol: "doc.on.doc", label: "複製", size: 25)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        row.addArrangedSubview(copyButton)

        configure(pauseButton, symbol: "pause.fill", label: "暫停", size: 25)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        row.addArrangedSubview(pauseButton)

        // The microphone is the one control that is always usable and always the
        // biggest: it is what the user came here for.
        micButton.layer.cornerRadius = 26
        micButton.layer.borderWidth = 1
        micButton.layer.borderColor = seal.cgColor
        micButton.tintColor = seal
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        micButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        micButton.accessibilityLabel = "Hushkey 麥克風"
        row.addArrangedSubview(micButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        spinner.color = seal
        micButton.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
        ])

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    private func configure(_ button: UIButton, symbol: String, label: String, size: CGFloat) {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.tintColor = ink
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    // MARK: state

    /// - Parameter needsSwitch: true when the app is not already resident, i.e.
    ///   tapping the microphone will open it. Drawn as an outlined microphone, the
    ///   same signal the reference product uses, so the user knows before tapping.
    func apply(phase: SharedStore.Phase, text: String, needsSwitch: Bool, paused: Bool) {
        self.paused = paused
        switch phase {
        case .recording:
            look = .recording
            statusLabel.text = text.isEmpty
                ? (paused ? "已暫停。按 ▶ 接著說。" : "錄音中…")
                : text
            statusLabel.textColor = paused ? dim : ink
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
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        micButton.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)

        micButton.backgroundColor = recording ? seal : .clear
        micButton.tintColor = recording ? .white : (look == .failed ? dim : seal)
        micButton.layer.borderColor = (look == .failed ? dim : seal).cgColor
        micButton.isEnabled = !working
        if working { spinner.startAnimating() } else { spinner.stopAnimating() }

        // Pause exists only while there is something to pause. Drawn anyway (dim)
        // so the row does not reflow under the user's thumb when recording starts.
        let pauseConfig = UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)
        pauseButton.setImage(
            UIImage(systemName: recording && paused ? "play.fill" : "pause.fill",
                    withConfiguration: pauseConfig),
            for: .normal
        )
        pauseButton.accessibilityLabel = recording && paused ? "繼續" : "暫停"
        pauseButton.isEnabled = recording
        pauseButton.alpha = recording ? 1 : 0.3

        let textAlpha: CGFloat = hasText ? 1 : 0.35
        copyButton.isEnabled = hasText
        copyButton.alpha = textAlpha
    }

    // MARK: actions

    @objc private func micTapped() { onMic?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func nextTapped() { onNext?() }
}
