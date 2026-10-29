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
/// anything. This is one label and a handful of buttons.
///
/// The 修改的提示詞 panel lives here too, folded away behind the pencil. It is
/// part of this view rather than a presented screen because a keyboard extension
/// has no room for a second view controller's worth of anything, and because the
/// keyboard's height is decided by these constraints -- a sheet would have to
/// resize the extension anyway.
final class VoiceBar: UIView, UITextFieldDelegate {
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
    /// The pencil: open (or close) the 修改的提示詞 panel.
    var onEdit: (() -> Void)?
    /// 用說的: ask for a dictation whose result becomes the instruction, rather
    /// than being typed at the cursor.
    var onVoiceInstruction: (() -> Void)?
    /// 套用: hand the typed instruction to whoever runs the model.
    var onEditApply: ((String) -> Void)?
    /// 開啟 Hushkey: the app is not running, so the edit has nowhere to run.
    var onOpenApp: (() -> Void)?

    /// How tall the keyboard is. Everything above this number is spent on the
    /// transcript, which is the part worth reading.
    static let height: CGFloat = 126

    /// With the 修改的提示詞 panel open. The extra is one field and one row of
    /// buttons; the transcript keeps its two lines, because the user still wants
    /// to see what is about to be changed.
    static let expandedHeight: CGFloat = 208

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)
    private let seal = UIColor(red: 0.76, green: 0.27, blue: 0.18, alpha: 1)
    private let dim = UIColor(red: 0.58, green: 0.55, blue: 0.51, alpha: 1)

    private let micButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private let panel = UIStackView()
    private let instructionField = UITextField()
    private let voiceButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!

    /// True while the panel is up. The controller asks before it overwrites the
    /// status line with a phase: the panel's own messages are the ones the user
    /// is acting on.
    var isEditing: Bool { !panel.isHidden }

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

        configure(editButton, symbol: "pencil", label: "修改的提示詞", size: 22)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        row.addArrangedSubview(editButton)

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

        buildPanel()
        column.addArrangedSubview(panel)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightConstraint,
        ])
    }

    /// The 修改的提示詞 panel: one field, three buttons.
    ///
    /// The field is editable with a hardware keyboard, which is what an iPad with
    /// a keyboard case has. It is NOT how a phone types: iOS does not present a
    /// system keyboard for a field inside a keyboard extension, so on a phone the
    /// instruction arrives through 用說的 -- the app records it, transcribes it,
    /// and the panel shows the words for the user to fix or apply. Both routes end
    /// at the same `套用`, which is the only thing that calls the model.
    private func buildPanel() {
        panel.axis = .vertical
        panel.spacing = 8
        panel.isHidden = true

        instructionField.delegate = self
        instructionField.font = .systemFont(ofSize: 14)
        instructionField.textColor = ink
        instructionField.tintColor = seal
        instructionField.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        instructionField.layer.cornerRadius = 8
        instructionField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        instructionField.leftViewMode = .always
        instructionField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        instructionField.rightViewMode = .always
        instructionField.returnKeyType = .done
        instructionField.clearButtonMode = .whileEditing
        instructionField.accessibilityLabel = "修改的提示詞"
        instructionField.attributedPlaceholder = NSAttributedString(
            string: "修改的提示詞（例：把三點改成四點）",
            attributes: [.foregroundColor: dim]
        )
        instructionField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        panel.addArrangedSubview(instructionField)

        let panelRow = UIStackView()
        panelRow.axis = .horizontal
        panelRow.alignment = .center
        panelRow.spacing = 8

        style(voiceButton, title: "用說的", symbol: "mic")
        voiceButton.addTarget(self, action: #selector(voiceInstructionTapped), for: .touchUpInside)
        panelRow.addArrangedSubview(voiceButton)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        panelRow.addArrangedSubview(spacer)

        style(openButton, title: "開啟 Hushkey", symbol: nil)
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        panelRow.addArrangedSubview(openButton)

        style(cancelButton, title: "取消", symbol: nil)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        panelRow.addArrangedSubview(cancelButton)

        style(applyButton, title: "套用", symbol: nil)
        applyButton.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)
        panelRow.addArrangedSubview(applyButton)

        panel.addArrangedSubview(panelRow)
    }

    private func style(_ button: UIButton, title: String, symbol: String?) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = ink
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 13, weight: .medium)
            return out
        }
        if let symbol {
            config.image = UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 12))
            config.imagePadding = 4
        }
        button.configuration = config
        button.accessibilityLabel = title
    }

    // MARK: panel

    /// Opens the panel. Idempotent: the controller calls this both when the
    /// pencil is tapped and when a dictation that was meant to be an instruction
    /// comes back to a keyboard that had to be recreated in the meantime.
    func showEditPanel(prefill: String = "") {
        panel.isHidden = false
        openButton.isHidden = true
        heightConstraint.constant = Self.expandedHeight
        if !prefill.isEmpty { instructionField.text = prefill }
        instructionField.becomeFirstResponder()
        superview?.layoutIfNeeded()
    }

    func hideEditPanel() {
        panel.isHidden = true
        openButton.isHidden = true
        heightConstraint.constant = Self.height
        instructionField.resignFirstResponder()
        instructionField.text = ""
        superview?.layoutIfNeeded()
    }

    /// The instruction as it stands, trimmed.
    var instructionText: String {
        (instructionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A one-line progress message that keeps the panel usable.
    func showWorking(_ message: String) {
        statusLabel.text = message
        statusLabel.textColor = ink.withAlphaComponent(0.8)
        look = .working
        paint(needsSwitch: false)
    }

    /// The app did not answer: it is not running. Says so and offers the way
    /// there, without switching apps on the user's behalf.
    func showAppNeeded() {
        statusLabel.text = "請先開啟 Hushkey 一次，再按「套用」"
        statusLabel.textColor = seal
        look = .failed
        openButton.isHidden = false
        paint(needsSwitch: true)
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
    @objc private func editTapped() { onEdit?() }
    @objc private func voiceInstructionTapped() { onVoiceInstruction?() }
    @objc private func cancelTapped() { hideEditPanel() }
    @objc private func openTapped() { onOpenApp?() }

    @objc private func applyTapped() {
        guard !instructionText.isEmpty else {
            statusLabel.text = "先輸入修改的提示詞。"
            statusLabel.textColor = seal
            return
        }
        onEditApply?(instructionText)
    }

    /// Return on the hardware keyboard is the same as 套用 -- the field is a
    /// one-line instruction, so there is nothing else it could mean.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        applyTapped()
        return false
    }
    @objc private func copyTapped() { onCopy?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func nextTapped() { onNext?() }
}
