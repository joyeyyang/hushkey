import UIKit

/// The whole keyboard: a microphone, a pause button, copy, the register, and the
/// words so far.
///
/// There is deliberately **no letter keyboard**. This extension exists for one
/// thing -- turning speech into text at the cursor -- and a QWERTY row under it
/// made it a worse English keyboard with a microphone attached. Someone who wants
/// to type switches back to their own keyboard with the globe on the left; that
/// button is not decoration, it is the only way out, so it stays even though
/// nothing else does.
///
/// The height is 216 pt, the number the system keyboard uses on a phone. The top
/// 44 pt is the status strip -- the same band the system spends on its candidate
/// row -- and it is where the transcript lives, because a keyboard that covers
/// the text the user is editing has to show what it heard somewhere. Below it is
/// one control row of 44×44 targets.
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
    /// 套用: hand the typed instruction to whoever runs the model. The second
    /// argument is the region the instruction is about ("whole" / "line" /
    /// "selection"); the third is the line number, 0 unless the region is a line.
    var onEditApply: ((String, String, Int) -> Void)?
    /// 插入: type the sentence the confirm panel was holding.
    var onInsertHeld: ((String) -> Void)?
    /// 丟棄: drop it. Nothing was typed, so this only has to clear the state the
    /// two processes keep about it.
    var onDiscardHeld: (() -> Void)?
    /// The register was changed here: "casual" / "normal" / "formal". The
    /// controller writes it to the App Group, which is what the app reads.
    var onToneChange: ((String) -> Void)?
    /// 開啟 Hushkey: the app is not running, so the edit has nowhere to run.
    var onOpenApp: (() -> Void)?

    /// The system keyboard's height on a phone, and the number this bar draws at.
    static let height: CGFloat = 216

    /// With the 修改的提示詞 panel open: one region row, one field, one button
    /// row. The transcript keeps whatever the strip has left, because the user
    /// still wants to see what is about to be changed.
    ///
    /// 216 + 104 + 8 of spacing, less the 34 the home indicator already owns:
    /// the panel fits without the transcript losing its 44 pt band.
    static let expandedHeight: CGFloat = 304

    /// The band at the top: the same 44 pt the system spends on candidates. The
    /// transcript gets it, and grows into the space the control row leaves.
    static let candidateBarHeight: CGFloat = 44

    /// One target size for every control, per the platform's own guidance.
    private static let controlSize: CGFloat = 44
    private static let margin: CGFloat = 12
    private static let gap: CGFloat = 8

    private let ink = UIColor(red: 0.93, green: 0.90, blue: 0.86, alpha: 1)
    private let seal = UIColor(red: 0.76, green: 0.27, blue: 0.18, alpha: 1)
    private let dim = UIColor(red: 0.58, green: 0.55, blue: 0.51, alpha: 1)

    private let micButton = UIButton(type: .system)
    private let pauseButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)
    private let toneControl = UISegmentedControl(items: ["輕鬆", "一般", "正式"])
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private let panel = UIStackView()
    /// The three regions, as chips rather than a `UISegmentedControl`: the middle
    /// one has to open a menu of the draft's lines, and a segmented control can
    /// only take a tap action, not a menu.
    private let regionRow = UIStackView()
    private let wholeChip = UIButton(type: .system)
    private let lineChip = UIButton(type: .system)
    private let selectionChip = UIButton(type: .system)
    private let instructionField = UITextField()
    private let voiceButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let openButton = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!

    /// "whole" / "line" / "selection" -- the same words the App Group request
    /// carries and the app's `PromptEditRegion` is built from.
    private var region = "whole"
    /// The line the 第 N 行 chip points at, 1-based. Kept here rather than read
    /// off the chip title, which is localised text.
    private var lineNumber = 1
    /// How many lines the draft has, for the line menu. Set by the controller.
    private var lineCount = 1

    /// True while the panel is up. The controller asks before it overwrites the
    /// status line with a phase: the panel's own messages are the ones the user
    /// is acting on.
    var isEditing: Bool { !panel.isHidden }

    /// True while the panel is holding a sentence for 插入.
    ///
    /// Separate from `isEditing` because the two need opposite treatment from the
    /// phase tick: an instruction panel can live *through* a recording (Mode 2
    /// records while the app stays in its small window), so its strip still has to
    /// show the words as they come, whereas a held sentence is the thing being
    /// confirmed and must not be painted over by anything.
    var isConfirming: Bool { !panel.isHidden && mode == .confirm }

    /// The text the confirm panel is holding.
    private var held = ""

    /// The register the bar is showing, as the core's own string.
    private(set) var tone = "normal"

    /// What the panel is for. The same stack view serves both, because a keyboard
    /// extension has no room for two of anything -- see `configurePanel`.
    private enum PanelMode { case edit, confirm }
    private var mode: PanelMode = .edit

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
        column.spacing = Self.gap
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        // The transcript, in the band the system would spend on candidates. It
        // is allowed to grow into whatever the control row leaves, because the
        // sentence being dictated is the one thing worth reading here.
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = dim
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byTruncatingHead
        statusLabel.setContentHuggingPriority(.init(1), for: .vertical)
        statusLabel.heightAnchor
            .constraint(greaterThanOrEqualToConstant: Self.candidateBarHeight)
            .isActive = true
        column.addArrangedSubview(statusLabel)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        column.addArrangedSubview(row)

        configure(globeButton, symbol: "globe", label: "下一個鍵盤", size: 18)
        globeButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        row.addArrangedSubview(globeButton)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        configure(editButton, symbol: "pencil", label: "修改的提示詞", size: 22)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        // A long press is 用說的 without opening the panel first: it starts the
        // same dictation and the panel opens when the words come back.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(editHeld(_:)))
        hold.minimumPressDuration = 0.4
        editButton.addGestureRecognizer(hold)
        row.addArrangedSubview(editButton)

        configure(copyButton, symbol: "doc.on.doc", label: "複製", size: 25)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        row.addArrangedSubview(copyButton)

        configure(pauseButton, symbol: "pause.fill", label: "暫停", size: 25)
        pauseButton.addTarget(self, action: #selector(pauseTapped), for: .touchUpInside)
        row.addArrangedSubview(pauseButton)

        // The microphone is the one control that is always usable and always the
        // biggest: it is what the user came here for.
        micButton.layer.cornerRadius = Self.controlSize / 2
        micButton.layer.borderWidth = 1
        micButton.layer.borderColor = seal.cgColor
        micButton.tintColor = seal
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.widthAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        micButton.heightAnchor.constraint(equalToConstant: Self.controlSize).isActive = true
        micButton.accessibilityLabel = "Hushkey 麥克風"
        row.addArrangedSubview(micButton)

        buildToneControl()
        row.addArrangedSubview(toneControl)

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
        // The bottom is the SAFE AREA's, not the view's: the extension's frame
        // reaches under the home indicator, and a row pinned to the view's bottom
        // would sit in the swipe-up area where the system eats the taps.
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.gap),
            column.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.gap),
            heightConstraint,
        ])
    }

    /// 輕鬆 / 一般 / 正式, immediately to the microphone's right.
    ///
    /// A segmented control rather than three buttons: one of three is always
    /// chosen, and the shape says so. It writes through `onToneChange` instead of
    /// touching the App Group itself, so the value has exactly one owner (the
    /// controller, which also reads it back when the app's settings change).
    private func buildToneControl() {
        toneControl.selectedSegmentIndex = 1
        toneControl.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.16)
        toneControl.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        toneControl.setTitleTextAttributes(
            [.foregroundColor: dim, .font: UIFont.systemFont(ofSize: 11, weight: .medium)],
            for: .normal
        )
        toneControl.setTitleTextAttributes(
            [.foregroundColor: ink, .font: UIFont.systemFont(ofSize: 11, weight: .semibold)],
            for: .selected
        )
        toneControl.accessibilityLabel = "回答模式"
        toneControl.addTarget(self, action: #selector(toneChanged), for: .valueChanged)
        // It must never truncate its own labels -- "…" three times is not a mode
        // picker. The spacer on the row's left is what gives up the width, not
        // this control.
        toneControl.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        toneControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// The 修改的提示詞 panel: a region, one field, one row of buttons.
    ///
    /// The region is first because it decides what the instruction means. 整段
    /// hands the whole draft to the core; 第 N 行 prepends the position the core
    /// resolves ("第3點…") and leaves the user's words untouched; 選取範圍 hands
    /// the selected slice over as if it were the whole text, so the rest of the
    /// draft cannot be rewritten.
    ///
    /// The field is editable with a hardware keyboard, which is what an iPad with
    /// a keyboard case has. It is NOT how a phone types: iOS does not present a
    /// system keyboard for a field inside a keyboard extension, so on a phone the
    /// instruction arrives through 用說的 -- the app records it, transcribes it,
    /// and the panel shows the words for the user to fix or apply. Both routes end
    /// at the same 套用, which is the only thing that calls the model.
    private func buildPanel() {
        panel.axis = .vertical
        panel.spacing = 6
        panel.isHidden = true

        regionRow.axis = .horizontal
        regionRow.spacing = 6
        regionRow.distribution = .fillEqually
        styleChip(wholeChip, title: "整段")
        styleChip(lineChip, title: "第 1 行")
        styleChip(selectionChip, title: "選取範圍")
        wholeChip.addTarget(self, action: #selector(wholeTapped), for: .touchUpInside)
        selectionChip.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
        // The middle chip is a menu button: tapping it lists the draft's lines
        // instead of selecting the region, and picking one does both.
        lineChip.showsMenuAsPrimaryAction = true
        regionRow.addArrangedSubview(wholeChip)
        regionRow.addArrangedSubview(lineChip)
        regionRow.addArrangedSubview(selectionChip)
        panel.addArrangedSubview(regionRow)
        paintRegion()

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

    /// One region chip: the same dark-on-dark shape as the field, so the panel
    /// reads as one block rather than three controls from three eras.
    private func styleChip(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        button.layer.cornerRadius = 7
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.accessibilityLabel = title
        paintChip(button, selected: false)
    }

    private func paintChip(_ button: UIButton, selected: Bool) {
        button.backgroundColor = UIColor.white.withAlphaComponent(selected ? 0.16 : 0.06)
        button.setTitleColor(selected ? ink : dim, for: .normal)
        button.titleLabel?.font = .systemFont(
            ofSize: 12, weight: selected ? .semibold : .medium
        )
    }

    private func paintRegion() {
        paintChip(wholeChip, selected: region == "whole")
        paintChip(lineChip, selected: region == "line")
        paintChip(selectionChip, selected: region == "selection")
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
        configurePanel(.edit)
        panel.isHidden = false
        heightConstraint.constant = Self.expandedHeight
        if !prefill.isEmpty { instructionField.text = prefill }
        instructionField.becomeFirstResponder()
        superview?.layoutIfNeeded()
    }

    func hideEditPanel() {
        panel.isHidden = true
        mode = .edit
        heightConstraint.constant = Self.height
        instructionField.resignFirstResponder()
        instructionField.text = ""
        region = "whole"
        paintRegion()
        superview?.layoutIfNeeded()
    }

    /// 貼上前確認: holds `text` -- shown in the strip, not typed -- until 插入.
    ///
    /// This is the phone's version of the Mac's editable HUD. The field is hidden
    /// on purpose: iOS will not present a system keyboard for a field inside a
    /// keyboard extension, so on a phone it is a box nobody can type into -- and
    /// the one thing this state needs is to be READ. The strip is the multi-line
    /// label (the field is one line, and truncated a sentence to "下週一上午十點
    /// 前把預算…"), and 重說一次 is the phone's way of fixing a word the
    /// recogniser got wrong.
    func showConfirmPanel(text: String) {
        held = text
        configurePanel(.confirm)
        panel.isHidden = false
        heightConstraint.constant = Self.expandedHeight
        statusLabel.text = text
        statusLabel.textColor = ink
        look = .done
        // ⧉ has to stay live here: the held sentence is the one text on this
        // keyboard the user is most likely to want somewhere else, and 複製 is the
        // way out that does not commit to inserting it.
        hasText = true
        paint(needsSwitch: false)
        superview?.layoutIfNeeded()
    }

    func hideConfirmPanel() {
        panel.isHidden = true
        mode = .edit
        held = ""
        heightConstraint.constant = Self.height
        superview?.layoutIfNeeded()
    }

    /// The panel's two lives, told apart by one enum rather than a spare bool.
    ///
    /// edit:    region chips + field + 用說的／取消／套用. The instruction route,
    ///          which sends words to the model.
    /// confirm: the button row only -- 重說一次／丟棄／插入 -- with the sentence
    ///          in the strip above it. Nothing here calls the model, which is the
    ///          whole point of the state: what was heard is what gets typed, and
    ///          only after the user has looked at it.
    private func configurePanel(_ next: PanelMode) {
        mode = next
        let confirming = next == .confirm
        openButton.isHidden = true
        regionRow.isHidden = confirming
        instructionField.isHidden = confirming
        if confirming {
            style(voiceButton, title: "重說一次", symbol: "mic")
            style(cancelButton, title: "丟棄", symbol: nil)
            style(applyButton, title: "插入", symbol: nil)
        } else {
            style(voiceButton, title: "用說的", symbol: "mic")
            style(cancelButton, title: "取消", symbol: nil)
            style(applyButton, title: "套用", symbol: nil)
        }
    }

    /// The instruction as it stands, trimmed.
    var instructionText: String {
        (instructionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "whole" / "line" / "selection", the same words the App Group request
    /// carries and the app's `PromptEditRegion` is built from.
    var editRegion: String { region }

    /// The line the 第 N 行 chip points at, 1-based; 0 for the other regions.
    var editLine: Int { region == "line" ? lineNumber : 0 }

    /// The lines the line picker offers, in the order the core numbers them.
    ///
    /// The keyboard cannot number the draft the way the core does without
    /// duplicating `numbered_items`, so the caller passes the lines it counted
    /// (`PromptEdit.lines` on the app side is the same rule). What the user picks
    /// here is what the core resolves, because the number goes into the
    /// instruction verbatim.
    func setDraftLines(_ lines: [String]) {
        currentLines = lines
        lineCount = max(1, lines.count)
        lineNumber = min(max(1, lineNumber), lineCount)
        rebuildLineMenu()
    }

    /// Kept so `selectLine` can rebuild the menu with the new check mark without
    /// the caller handing the lines over again.
    private var currentLines: [String] = []

    private func rebuildLineMenu() {
        lineChip.setTitle("第 \(lineNumber) 行 ▾", for: .normal)
        let actions = currentLines.enumerated().map { index, text in
            UIAction(
                title: "第 \(index + 1) 行：\(Self.preview(text))",
                state: index + 1 == lineNumber ? .on : .off
            ) { [weak self] _ in
                self?.selectLine(index + 1)
            }
        }
        lineChip.menu = UIMenu(children: actions.isEmpty
            ? [UIAction(title: "沒有可選的行", attributes: .disabled) { _ in }]
            : actions)
    }

    private func selectLine(_ number: Int) {
        lineNumber = min(max(1, number), lineCount)
        region = "line"
        paintRegion()
        rebuildLineMenu()
    }

    private static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 14 ? flat : String(flat.prefix(14)) + "…"
    }

    /// The non-empty lines of a draft, in the order the core numbers them.
    ///
    /// Bullets and existing numbers are stripped for the menu's title only; the
    /// COUNT is what has to agree with the core, because the number the user
    /// picks is the number the core resolves. Same rule as the app's
    /// `PromptEdit.lines`, which the keyboard cannot import (different target).
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                var body = line
                for bullet in ["• ", "- ", "・"] where body.hasPrefix(bullet) {
                    body = String(body.dropFirst(bullet.count))
                }
                if let dot = body.firstIndex(where: { $0 == "." || $0 == "、" || $0 == ")" }) {
                    let head = body[body.startIndex..<dot]
                    if !head.isEmpty, head.allSatisfy({ $0.isNumber }) {
                        body = String(body[body.index(after: dot)...])
                    }
                }
                return body.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
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

    /// A long press on the pencil starts 用說的 directly: the panel is where the
    /// instruction ends up, so opening it first is a step the user does not need.
    @objc private func editHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onVoiceInstruction?()
    }

    @objc private func voiceInstructionTapped() { onVoiceInstruction?() }

    /// 取消 in the instruction panel, 丟棄 in the confirm panel: two different
    /// outcomes for the same place on screen. Cancelling an instruction abandons a
    /// request that was never sent; discarding a held sentence is a decision about
    /// text that exists, so it is the controller's to complete (it is the side
    /// that knows whether the sentence is still the current one).
    @objc private func cancelTapped() {
        if mode == .confirm { onDiscardHeld?() } else { hideEditPanel() }
    }
    @objc private func openTapped() { onOpenApp?() }

    @objc private func wholeTapped() {
        region = "whole"
        paintRegion()
    }

    @objc private func selectionTapped() {
        region = "selection"
        paintRegion()
    }

    @objc private func toneChanged() {
        tone = Self.toneValue(for: toneControl.selectedSegmentIndex)
        onToneChange?(tone)
    }

    /// Shows the register the app's settings hold, without telling anyone about
    /// it: this is the reading half of the two-way sync, and reporting it back
    /// would be a write loop between two processes.
    func setTone(_ value: String) {
        guard value != tone else { return }
        tone = value
        let index = Self.toneIndex(for: value)
        guard toneControl.selectedSegmentIndex != index else { return }
        toneControl.selectedSegmentIndex = index
    }

    static func toneIndex(for value: String) -> Int {
        switch value {
        case "casual": return 0
        case "formal": return 2
        default: return 1
        }
    }

    static func toneValue(for index: Int) -> String {
        switch index {
        case 0: return "casual"
        case 2: return "formal"
        default: return "normal"
        }
    }

    @objc private func applyTapped() {
        // 插入 confirms; 套用 asks the model. The same button, and the only place
        // the two panels differ in what a tap means.
        if mode == .confirm {
            onInsertHeld?(held)
            return
        }
        guard !instructionText.isEmpty else {
            statusLabel.text = "先輸入修改的提示詞。"
            statusLabel.textColor = seal
            return
        }
        onEditApply?(instructionText, editRegion, editLine)
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

// MARK: - A spoken line that is an instruction

/// Whether a recognised line is an instruction to EDIT something rather than
/// text to paste.
///
/// Ported from the Mac's `VoiceEdit.swift` (`isVoiceEditInstruction` and its
/// helpers), where it decides whether a dictation applies to the text before the
/// cursor instead of being inserted. The predicate is a pure function of its
/// argument: no model, no draft, no I/O -- which is what lets the keyboard decide
/// in the half-second after recognition, on a phone that cannot afford a second
/// inference to ask "did they mean to edit?".
///
/// The gate requires BOTH an edit verb and a reference to the thing being
/// edited, and that conjunction is the entire safety property. A false positive
/// is expensive: the user's words would be applied as an edit to whatever came
/// before instead of being inserted where they are speaking. A false negative
/// costs almost nothing, because the refine prompt already applies a spoken
/// instruction it finds inside a draft. So this errs towards missing.
///
/// Here the verdict is used for one thing only: a dictation that reads as an
/// instruction opens the 修改的提示詞 panel with those words in it, instead of
/// being typed at the cursor. Nothing is applied without 套用, so even a false
/// positive costs one tap rather than the sentence.
///
/// Samples this was built against, identical to the Mac's test target
/// (`VoiceEditInstructionTests`), so the two copies can be re-checked against the
/// same list:
///
///   accepted: 把第二點改成禮拜五下午兩點
///             第三句刪掉
///             delete the second one
///             把最後一句改短一點
///             把地點改成三樓會議室
///             把小林改成大衛
///             把三點改成四點
///             第二句改短一點
///   rejected: 顏色改成藍色
///             我把檔案刪掉了
///             這個會議改成線上開
///             我用英文寫了一封信
///             第一點要改善
///             最後一段需要修改
func isVoiceEditInstruction(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return containsEditVerb(trimmed) && containsEditTarget(trimmed)
}

/// The verb half. Latin verbs match whole words only, so "change" does not fire
/// inside "exchange". The Chinese list is substring matching, which is what
/// Chinese allows -- there are no token boundaries to anchor to -- and it includes
/// bare 改 as a stem so 改短／改一下 all count; a bare stem is safe here precisely
/// because the verb alone is never enough.
private func containsEditVerb(_ text: String) -> Bool {
    let chinese = ["改成", "改為", "換成", "刪掉", "刪除", "拿掉", "去掉", "移除",
                   "縮短", "精簡", "重寫", "變成", "移到", "調順序", "加一句", "補一句",
                   "改短", "改長", "改小", "改大", "改多", "改少", "改簡", "改複"]
    if chinese.contains(where: { text.contains($0) }) { return true }
    // The bare stem 改 only counts inside an imperative frame: on its own it is a
    // substring of 改善／修改／改天, so "第一點要改善" -- an ordinary sentence about
    // text -- would read as an instruction.
    if text.contains("改") && ["把", "請", "幫", "將", "給我"].contains(where: { text.contains($0) }) {
        return true
    }

    let latin = ["change", "replace", "delete", "remove", "shorten", "rewrite", "make it"]
    let lower = text.lowercased()
    return latin.contains { containsWord(lower, $0) }
}

/// The target half: a pointer at the line the instruction is about.
///
/// The core resolves the target in one of two ways, and this gate has to
/// recognise the same two, or it turns away instructions the core can carry
/// out: a POSITION ("第二句", "the third one") and a CONTENT WORD ("把地點改成
/// 三樓會議室").
private func containsEditTarget(_ text: String) -> Bool {
    // 第 + a number + a unit: 第二點, 第3句, 第十段. 最後一句 is handled below.
    if text.range(of: "第[0-9一二三四五六七八九十兩]+[段句點行條個]",
                  options: .regularExpression) != nil { return true }
    // The line or paragraph just written.
    if ["這句", "這段", "這一段"].contains(where: { text.contains($0) }) { return true }
    // A positional pointer. 那 is optional: 最後一句 and 最後那句 mean the same.
    if text.range(of: "(前面|最後|後面|上面|下面)(那|一)?[段句點行條個]",
                  options: .regularExpression) != nil { return true }

    // Latin pointers: a bare "that line", or an ordinal acting as a determiner.
    let lower = text.lowercased()
    if ["that line", "that sentence", "that paragraph"].contains(where: { lower.contains($0) }) {
        return true
    }
    for ordinal in ["the first", "the second", "the last"] {
        var search = lower.startIndex..<lower.endIndex
        while let range = lower.range(of: ordinal, range: search) {
            if ordinalFollowedByNoun(lower, after: range.upperBound) { return true }
            search = range.upperBound..<lower.endIndex
        }
    }
    // A CONTENT WORD: the thing named before the change verb ("把地點改成…" names
    // 地點). The same extraction the core does, so the gate agrees with what the
    // core can actually resolve.
    if editContentWord(text) != nil { return true }
    return false
}

/// The word an instruction names as the thing to change, if it names one.
///
/// Take what comes BEFORE the change verb (that is the target; what comes after
/// is the replacement), strip the framing words, and keep what is left. The
/// instruction has to READ as an instruction, not as a sentence about changing
/// something: "把地點改成…" is an order, "顏色改成藍色" is a statement.
private func editContentWord(_ text: String) -> String? {
    guard hasImperativeFrame(text) else { return nil }
    let verbs = ["改成", "換成", "改為", "換", "改", "刪掉", "刪除", "拿掉", "去掉"]
    var head = text
    for verb in verbs {
        if let at = head.range(of: verb) {
            head = String(head[head.startIndex..<at.lowerBound])
            break
        }
    }
    // The framing words are the ones that say nothing about WHAT is changing.
    let framing = ["請幫我", "幫我", "請", "幫", "把", "給我", "我要", "我想", "要", "的", "了"]
    for word in framing {
        head = head.replacingOccurrences(of: word, with: " ")
    }
    let parts = head.split(whereSeparator: { $0.isWhitespace || "，,。.、；;：:！!？?「」『』".contains($0) })
    for part in parts {
        let candidate = part.trimmingCharacters(in: .whitespaces)
        // A single character is too short to be a target on its own, and a bare
        // number is a position, which is handled above.
        guard candidate.count >= 2 else { continue }
        if candidate.allSatisfy({ $0.isNumber }) { continue }
        return candidate
    }
    return nil
}

/// True when the instruction opens like an order rather than like a statement.
///
/// The frame has to be at the FRONT: "把地點改成三樓會議室" is an order, and
/// "我把檔案刪掉了" has the same 把 with 我 in front of it, which makes it a
/// report of something already done.
private func hasImperativeFrame(_ text: String) -> Bool {
    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // The politeness that can come first: 請 / 幫我 / 麻煩 / 能不能.
    let lead = ["請幫我", "幫我", "請", "麻煩", "能不能", "可以"]
    var changed = true
    while changed {
        changed = false
        for word in lead where rest.hasPrefix(word) {
            rest = String(rest.dropFirst(word.count))
            rest = rest.trimmingCharacters(in: .whitespaces)
            changed = true
        }
    }
    // The Chinese order frame.
    if ["把", "將"].contains(where: { rest.hasPrefix($0) }) { return true }
    // The English one: the verb opens the sentence. "I deleted the file" has
    // the verb in the middle and is a statement.
    let lower = rest.lowercased()
    let verbs = ["change", "replace", "delete", "remove", "shorten", "rewrite", "make it"]
    return verbs.contains { lower.hasPrefix($0) }
}

/// True when an ordinal is a determiner for a following word: "the second one"
/// is a target, a trailing "the second" is not, and "the second-guess" is not
/// either -- a hyphen is not the space a noun needs.
private func ordinalFollowedByNoun(_ lower: String, after index: String.Index) -> Bool {
    var i = index
    var sawSpace = false
    while i < lower.endIndex {
        let character = lower[i]
        if character.isLetter { return sawSpace }
        guard character == " " else { return false }
        sawSpace = true
        i = lower.index(after: i)
    }
    return false
}

/// Whole-word lookup in already-lowercased text: neither character flanking the
/// match may be a letter. Latin gets this and Chinese does not because only
/// Latin writes words without spaces between them.
private func containsWord(_ lower: String, _ needle: String) -> Bool {
    var search = lower.startIndex..<lower.endIndex
    while let range = lower.range(of: needle, range: search) {
        let beforeIsBoundary = range.lowerBound == lower.startIndex
            || !lower[lower.index(before: range.lowerBound)].isLetter
        let afterIsBoundary = range.upperBound == lower.endIndex
            || !lower[range.upperBound].isLetter
        if beforeIsBoundary && afterIsBoundary { return true }
        search = range.upperBound..<lower.endIndex
    }
    return false
}

