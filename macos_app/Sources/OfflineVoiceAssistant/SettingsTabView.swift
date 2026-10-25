import AppKit
import QuartzCore

/// The 設定 tab: five cards on the window's paper instead of one long form.
///
/// This view never writes to `UserDefaults`. Every change leaves through a
/// callback so the controller owns persistence; `syncFromDefaults` is the only
/// reader and fires nothing.
final class SettingsTabView: NSView, NSTextFieldDelegate {
    // MARK: - Public API

    /// Theme code: "system" | "paper" | "night" | "slate" | "moss" | "clay".
    var onThemeChange: ((String) -> Void)?
    var onHotkeyChange: ((String) -> Void)?
    /// "auto" | "off" | "en" | "zh".
    var onTranslateChange: ((String) -> Void)?
    var onPolishChange: ((Bool) -> Void)?
    var onConfirmChange: ((Bool) -> Void)?
    var onSystemAudioChange: ((Bool) -> Void)?
    var onExportSettingsChange: ((ExportSettings) -> Void)?
    var onExportNow: (() -> Void)?
    var onQuit: (() -> Void)?

    // MARK: - Private state

    private static let noFolder = "（未選擇）"

    private var theme: Theme
    /// The palette currently in force, so the 跟隨系統 swatch can show it.
    private var appliedTheme: Theme = ThemeCatalog.current
    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    private var cards: [ThemeCard] = []
    private var headers: [SectionHeader] = []
    private var primaryLabels: [NSTextField] = []
    private var captionLabels: [NSTextField] = []
    private var toggleRows: [ToggleRowView] = []
    private var themeRows: [ThemeRowView] = []
    private var choiceRows: [ChoiceRowView] = []

    /// Holds the chosen theme code. The swatch rows are only a visual front end
    /// for this popup, which is why it never joins the view hierarchy.
    private let themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hotkeyField = NSTextField()
    private var lastHotkey = "Option+Space"

    private let polishSwitch = NSSwitch(frame: .zero)
    private let confirmSwitch = NSSwitch(frame: .zero)
    private let systemAudioSwitch = NSSwitch(frame: .zero)

    private let exportFormatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let exportFolderLabel = NSTextField(labelWithString: "")
    private let exportChooseButton: ThemedButton
    private let exportNowButton: ThemedButton
    private let exportAutoSwitch = NSSwitch(frame: .zero)

    private let resetButton: ThemedButton
    private let quitButton: ThemedButton

    private var translateSelection = 0

    private let translateCodes = ["auto", "off", "en", "zh"]
    private let translateTitles = [
        "自動（預設繁體中文，依你的指令改變）",
        "關閉",
        "一律翻成英文",
        "一律翻成繁體中文",
    ]

    private var themeCodes: [String] { ["system"] + ThemeCatalog.all.map(\.id) }
    private var themeTitles: [String] { ["跟隨系統"] + ThemeCatalog.all.map(\.name) }

    // MARK: - Lifecycle

    init(theme: Theme) {
        self.theme = theme
        self.exportChooseButton = ThemedButton("選擇資料夾…", kind: .secondary, theme: theme)
        self.exportNowButton = ThemedButton("匯出最近一次逐字稿…", kind: .secondary, theme: theme)
        self.resetButton = ThemedButton("重設為預設", kind: .secondary, theme: theme)
        self.quitButton = ThemedButton("結束 Offline Voice Assistant", kind: .danger, theme: theme)
        super.init(frame: .zero)
        buildUI()
        applyTheme(theme)
        syncFromDefaults()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    /// Follows the chosen palette. Native controls (popups, switches, the hotkey
    /// field) follow through the window appearance; our own drawing is redone
    /// here.
    func applyTheme(_ theme: Theme) {
        appliedTheme = theme
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        cards.forEach { $0.applyTheme(theme) }
        headers.forEach { $0.applyTheme(theme) }
        primaryLabels.forEach { $0.textColor = theme.textPrimary }
        captionLabels.forEach { $0.textColor = theme.textSecondary }
        toggleRows.forEach { $0.applyTheme(theme) }
        choiceRows.forEach { $0.applyTheme(theme) }
        themeRows.forEach { $0.applyTheme(theme) }
        themeRows.first?.setPalette(systemPalette)

        hotkeyField.font = theme.fontMono
        hotkeyField.textColor = theme.textPrimary
        exportFolderLabel.font = theme.fontMono
        exportFolderLabel.textColor = theme.textSecondary
        exportFormatPopUp.font = theme.fontBody

        exportChooseButton.applyTheme(theme)
        exportNowButton.applyTheme(theme)
        resetButton.applyTheme(theme)
        quitButton.applyTheme(theme)

        refreshThemeRows()
        for (index, row) in choiceRows.enumerated() {
            row.setSelected(index == translateSelection, theme: theme)
        }
    }

    /// Populates every control from what the app has stored. Fires no callbacks.
    func syncFromDefaults() {
        let defaults = UserDefaults.standard

        let storedTheme = defaults.string(forKey: "settings.theme") ?? "system"
        selectTheme(code: normalizedThemeCode(storedTheme), notify: false)

        let hotkey = defaults.string(forKey: "settings.hotkey") ?? "Option+Space"
        hotkeyField.stringValue = hotkey
        lastHotkey = hotkey

        let translate = defaults.string(forKey: "settings.translate") ?? "auto"
        selectTranslate(code: normalizedTranslateCode(translate), notify: false)

        polishSwitch.state = storedBool(defaults, "settings.polish", fallback: true) ? .on : .off
        confirmSwitch.state = storedBool(defaults, "settings.confirmInsert", fallback: false) ? .on : .off
        systemAudioSwitch.state = storedBool(defaults, "settings.meetingSystemAudio", fallback: true) ? .on : .off

        let export = ExportSettings.load()
        setFolder(export.folder)
        if let index = ExportFormat.allCases.firstIndex(of: export.format) {
            exportFormatPopUp.selectItem(at: index)
        }
        exportAutoSwitch.state = export.autoSave ? .on : .off
    }

    /// Sets every control to its default and reports all of them, so the caller
    /// persists the reset exactly as if the user had changed each one.
    func resetToDefaults() {
        selectTheme(code: "system", notify: false)
        hotkeyField.stringValue = "Option+Space"
        lastHotkey = "Option+Space"
        selectTranslate(code: "auto", notify: false)
        polishSwitch.state = .on
        confirmSwitch.state = .off
        systemAudioSwitch.state = .on
        setFolder("")
        exportFormatPopUp.selectItem(at: ExportFormat.allCases.firstIndex(of: .markdown) ?? 0)
        exportAutoSwitch.state = .off

        onThemeChange?("system")
        onHotkeyChange?("Option+Space")
        onTranslateChange?("auto")
        onPolishChange?(true)
        onConfirmChange?(false)
        onSystemAudioChange?(true)
        onExportSettingsChange?(currentExportSettings)
    }

    // MARK: - Layout

    private func buildUI() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Metrics.space4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(contentStack)

        // Prefer the clip view's height when the cards are shorter, and grow
        // past it when they are not; without this the document height is only
        // bounded from below and the scroll extent is under-determined.
        let fillHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        fillHeight.priority = NSLayoutConstraint.Priority(1)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // A fixed document width means the long captions wrap instead of
            // growing a horizontal scrollbar.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                                  constant: Metrics.space4),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                                   constant: -Metrics.space4),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor,
                                              constant: Metrics.space4),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor,
                                                 constant: -Metrics.space4),
            document.heightAnchor.constraint(greaterThanOrEqualTo: contentStack.heightAnchor,
                                             constant: Metrics.space6),
            fillHeight,
        ])

        buildThemeCard()
        buildDictationCard()
        buildTranslateCard()
        buildExportCard()
        buildOtherCard()
    }

    @discardableResult
    private func addCard(_ title: String) -> NSStackView {
        let card = ThemeCard(theme: theme)
        cards.append(card)

        let stack = NSStackView.column([], spacing: Metrics.space3)
        let header = SectionHeader(title, theme: theme)
        headers.append(header)
        addFullWidth(header, to: stack)

        card.embed(stack, inset: Metrics.space4)
        addFullWidth(card, to: contentStack)
        return stack
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func bodyText(_ text: String) -> NSTextField {
        let label = Ink.body(text, theme)
        primaryLabels.append(label)
        return label
    }

    private func captionText(_ text: String) -> NSTextField {
        let label = Ink.caption(text, theme)
        captionLabels.append(label)
        return label
    }

    /// Low hugging and compression resistance: the stack gives it the spare
    /// width, which is what pushes the control to the right edge.
    private func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                     for: .horizontal)
        return view
    }

    // MARK: - Cards

    private func buildThemeCard() {
        let card = addCard("外觀")

        themePopUp.addItems(withTitles: themeTitles)
        themePopUp.target = self
        themePopUp.action = #selector(didChangeThemePopUp)

        let list = NSStackView.column([], spacing: Metrics.space1)
        let palettes = [systemPalette] + ThemeCatalog.all
        let titles = themeTitles
        for index in themeCodes.indices {
            let palette = palettes[index]
            let tag = index == 0 ? "依 macOS 外觀" : (palette.isDark ? "深色" : "淺色")
            let row = ThemeRowView(title: titles[index], tag: tag,
                                   palette: palette, theme: theme)
            row.onSelect = { [weak self] in self?.selectTheme(at: index, notify: true) }
            addFullWidth(row, to: list)
            themeRows.append(row)
        }
        addFullWidth(list, to: card)
        addFullWidth(captionText("「跟隨系統」會依 macOS 淺色／深色自動切換；其他選項固定使用該紙色。"),
                     to: card)
    }

    private func buildDictationCard() {
        let card = addCard("聽寫")

        addFullWidth(bodyText("啟用熱鍵"), to: card)

        hotkeyField.font = theme.fontMono
        hotkeyField.textColor = theme.textPrimary
        hotkeyField.placeholderString = "例如：Option+Space"
        hotkeyField.isBezeled = true
        hotkeyField.drawsBackground = true
        hotkeyField.bezelStyle = .roundedBezel
        hotkeyField.focusRingType = .exterior
        hotkeyField.delegate = self
        hotkeyField.target = self
        hotkeyField.action = #selector(commitHotkey)
        addFullWidth(hotkeyField, to: card)

        addFullWidth(captionText("格式：修飾鍵 + 按鍵，例如 Option+Space、Control+Shift+R。"),
                     to: card)

        addFullWidth(makeToggleRow(title: "AI 整理",
                                   caption: "關閉後直接用語音辨識的原始結果，不再潤飾。",
                                   control: polishSwitch,
                                   action: #selector(didTogglePolish)), to: card)
        addFullWidth(makeToggleRow(title: "貼上前確認",
                                   caption: "開啟後先顯示文字，按 Enter 才貼到游標處。",
                                   control: confirmSwitch,
                                   action: #selector(didToggleConfirm)), to: card)
        addFullWidth(makeToggleRow(title: "會議也錄系統音訊",
                                   caption: "需要「螢幕與系統音訊錄製」權限；戴耳機可避免重複收音。",
                                   control: systemAudioSwitch,
                                   action: #selector(didToggleSystemAudio)), to: card)
    }

    private func buildTranslateCard() {
        let card = addCard("翻譯")

        let list = NSStackView.column([], spacing: Metrics.space1)
        for index in translateCodes.indices {
            let row = ChoiceRowView(title: translateTitles[index], theme: theme)
            row.onSelect = { [weak self] in self?.selectTranslate(at: index, notify: true) }
            addFullWidth(row, to: list)
            choiceRows.append(row)
        }
        addFullWidth(list, to: card)
        addFullWidth(captionText("「自動」會保留你在指令裡指定的語言；沒指定時一律輸出繁體中文。"),
                     to: card)
    }

    private func buildExportCard() {
        let card = addCard("匯出")

        exportFormatPopUp.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        exportFormatPopUp.target = self
        exportFormatPopUp.action = #selector(didChangeExportControls)

        let formatRow = NSStackView.row([bodyText("格式"), spacer(), exportFormatPopUp])
        formatRow.distribution = .fill
        addFullWidth(formatRow, to: card)

        exportChooseButton.target = self
        exportChooseButton.action = #selector(didChooseExportFolder)

        exportFolderLabel.stringValue = Self.noFolder
        exportFolderLabel.font = theme.fontMono
        exportFolderLabel.textColor = theme.textSecondary
        exportFolderLabel.lineBreakMode = .byTruncatingMiddle
        exportFolderLabel.maximumNumberOfLines = 1
        exportFolderLabel.cell?.usesSingleLineMode = true
        exportFolderLabel.cell?.truncatesLastVisibleLine = true
        exportFolderLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                                  for: .horizontal)
        exportFolderLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                                    for: .horizontal)
        exportFolderLabel.translatesAutoresizingMaskIntoConstraints = false

        let folderRow = NSStackView.row([exportChooseButton, exportFolderLabel])
        folderRow.distribution = .fill
        addFullWidth(folderRow, to: card)

        addFullWidth(makeToggleRow(title: "自動匯出",
                                   caption: "每次結束時，自動把逐字稿匯出到上面的資料夾。",
                                   control: exportAutoSwitch,
                                   action: #selector(didChangeExportControls)), to: card)

        exportNowButton.target = self
        exportNowButton.action = #selector(didTapExportNow)
        addFullWidth(exportNowButton, to: card)
    }

    private func buildOtherCard() {
        let card = addCard("其他")

        resetButton.target = self
        resetButton.action = #selector(didTapReset)
        quitButton.target = self
        quitButton.action = #selector(didTapQuit)

        let row = NSStackView.row([resetButton, spacer(), quitButton])
        row.distribution = .fill
        addFullWidth(row, to: card)
        addFullWidth(captionText("重設只還原這一頁的選項，不會刪除歷史紀錄或已下載的模型。"),
                     to: card)
    }

    private func makeToggleRow(title: String, caption: String,
                               control: NSSwitch, action: Selector) -> ToggleRowView {
        control.target = self
        control.action = action
        control.setAccessibilityLabel(title)
        let row = ToggleRowView(title: title, caption: caption, theme: theme, control: control)
        toggleRows.append(row)
        return row
    }

    // MARK: - Theme selection

    private var selectedThemeCode: String {
        let index = themePopUp.indexOfSelectedItem
        return themeCodes.indices.contains(index) ? themeCodes[index] : "system"
    }

    /// The swatch for "跟隨系統" shows what that choice currently resolves to,
    /// not the theme the window is wearing right now.
    /// The palette the window is wearing right now.
    ///
    /// Reading the window's appearance instead was wrong twice over: the view
    /// can be off-screen (so `window` is nil) and a pinned paper theme is not
    /// the system appearance anyway. The row means "what you get if you leave
    /// it on 跟隨系統", and the window is already showing exactly that.
    private var systemPalette: Theme { appliedTheme }

    private func selectTheme(at index: Int, notify: Bool) {
        guard themeCodes.indices.contains(index) else { return }
        themePopUp.selectItem(at: index)
        refreshThemeRows()
        if notify { onThemeChange?(themeCodes[index]) }
    }

    private func selectTheme(code: String, notify: Bool) {
        selectTheme(at: themeCodes.firstIndex(of: code) ?? 0, notify: notify)
    }

    private func refreshThemeRows() {
        let selected = themePopUp.indexOfSelectedItem
        for (index, row) in themeRows.enumerated() {
            row.setSelected(index == selected, theme: theme)
        }
    }

    private func normalizedThemeCode(_ raw: String) -> String {
        // The two codes the app used before the palettes had names.
        switch raw {
        case "light": return "paper"
        case "dark": return "night"
        default: return themeCodes.contains(raw) ? raw : "system"
        }
    }

    // MARK: - Translate selection

    private func selectTranslate(at index: Int, notify: Bool) {
        guard translateCodes.indices.contains(index) else { return }
        translateSelection = index
        for (rowIndex, row) in choiceRows.enumerated() {
            row.setSelected(rowIndex == index, theme: theme)
        }
        if notify { onTranslateChange?(translateCodes[index]) }
    }

    private func selectTranslate(code: String, notify: Bool) {
        selectTranslate(at: translateCodes.firstIndex(of: code) ?? 0, notify: notify)
    }

    private func normalizedTranslateCode(_ raw: String) -> String {
        translateCodes.contains(raw) ? raw : "auto"
    }

    // MARK: - Export state

    /// Reads the three controls as one value. The folder comes from the label,
    /// so a later toggle cannot persist a path the panel once returned.
    private var currentExportSettings: ExportSettings {
        let index = exportFormatPopUp.indexOfSelectedItem
        let format = ExportFormat.allCases.indices.contains(index)
            ? ExportFormat.allCases[index]
            : .markdown
        let shown = exportFolderLabel.stringValue
        return ExportSettings(folder: shown == Self.noFolder ? "" : shown,
                              format: format,
                              autoSave: exportAutoSwitch.state == .on)
    }

    private func setFolder(_ path: String) {
        exportFolderLabel.stringValue = path.isEmpty ? Self.noFolder : path
        exportFolderLabel.toolTip = path.isEmpty ? nil : path
    }

    private func storedBool(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    // MARK: - Actions

    @objc private func didChangeThemePopUp() {
        refreshThemeRows()
        onThemeChange?(selectedThemeCode)
    }

    @objc private func commitHotkey() {
        let value = hotkeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            hotkeyField.stringValue = lastHotkey
            return
        }
        hotkeyField.stringValue = value
        guard value != lastHotkey else { return }
        lastHotkey = value
        onHotkeyChange?(value)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === hotkeyField else { return }
        commitHotkey()
    }

    @objc private func didTogglePolish() {
        onPolishChange?(polishSwitch.state == .on)
    }

    @objc private func didToggleConfirm() {
        onConfirmChange?(confirmSwitch.state == .on)
    }

    @objc private func didToggleSystemAudio() {
        onSystemAudioChange?(systemAudioSwitch.state == .on)
    }

    @objc private func didChangeExportControls() {
        onExportSettingsChange?(currentExportSettings)
    }

    @objc private func didChooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選擇"
        panel.message = "選擇匯出資料夾（例如 Obsidian vault 裡的某個資料夾）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url.path)
        onExportSettingsChange?(currentExportSettings)
    }

    @objc private func didTapExportNow() { onExportNow?() }
    @objc private func didTapReset() { resetToDefaults() }
    @objc private func didTapQuit() { onQuit?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeRows.first?.setPalette(systemPalette)
    }
}

// MARK: - Theme row

/// One palette as a row: three colour chips plus its Chinese name. Selecting it
/// is the picker; the popup behind it only stores the code.
private final class ThemeRowView: NSView {
    var onSelect: (() -> Void)?

    private let swatch: ThemeSwatch
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")
    private var theme: Theme
    private var selected = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, tag: String, palette: Theme, theme: Theme) {
        self.theme = theme
        self.swatch = ThemeSwatch(theme: palette)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        nameLabel.stringValue = title
        nameLabel.font = theme.fontBody
        nameLabel.textColor = theme.textPrimary
        nameLabel.isSelectable = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        tagLabel.stringValue = tag
        tagLabel.font = theme.fontSmall
        tagLabel.textColor = theme.textSecondary
        tagLabel.isSelectable = false
        tagLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(swatch)
        addSubview(nameLabel)
        addSubview(tagLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor,
                                               constant: Metrics.space3),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            tagLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor,
                                              constant: Metrics.space2),
            tagLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            tagLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                               constant: -Metrics.space3),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        nameLabel.font = theme.fontBody
        nameLabel.textColor = theme.textPrimary
        tagLabel.font = theme.fontSmall
        tagLabel.textColor = theme.textSecondary
        restyle()
    }

    func setSelected(_ selected: Bool, theme: Theme) {
        self.selected = selected
        self.theme = theme
        restyle()
    }

    func setPalette(_ palette: Theme) {
        swatch.setPalette(palette)
    }

    private func restyle() {
        let fill: NSColor
        if selected {
            fill = theme.accentQuiet
        } else if hovering {
            fill = theme.surfaceAlt
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (selected ? theme.accent.withAlphaComponent(0.55) : .clear).cgColor
        setAccessibilityValue(selected ? 1 : 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Colour chips

/// Background / surface / accent, so the menu reads as a choice of paper rather
/// than a list of names.
private final class ThemeSwatch: NSView {
    private let backgroundLayer = CALayer()
    private let surfaceLayer = CALayer()
    private let accentLayer = CALayer()

    init(theme: Theme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for chip in [backgroundLayer, surfaceLayer, accentLayer] {
            chip.cornerRadius = 4
            layer?.addSublayer(chip)
        }
        // A hairline on every chip keeps light palettes readable, where the
        // background chip is nearly the same color as the card behind it.
        for chip in [backgroundLayer, surfaceLayer, accentLayer] {
            chip.borderWidth = 1
        }

        setPalette(theme)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 50),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPalette(_ theme: Theme) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hairline = theme.border.withAlphaComponent(0.55).cgColor
        for chip in [backgroundLayer, surfaceLayer, accentLayer] {
            chip.borderColor = hairline
        }
        backgroundLayer.backgroundColor = theme.background.cgColor
        surfaceLayer.backgroundColor = theme.surface.cgColor
        accentLayer.backgroundColor = theme.accent.cgColor
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 14
        let gap: CGFloat = 4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, chip) in [backgroundLayer, surfaceLayer, accentLayer].enumerated() {
            chip.frame = CGRect(x: CGFloat(index) * (side + gap),
                                y: (bounds.height - side) / 2,
                                width: side,
                                height: side)
        }
        CATransaction.commit()
    }
}

// MARK: - Choice row

/// A radio row for the four translation directions.
private final class ChoiceRowView: NSView {
    var onSelect: (() -> Void)?

    private let dot = SelectionDot()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private var theme: Theme
    private var selected = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(title: String, theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        titleLabel.stringValue = title
        titleLabel.font = theme.fontBody
        titleLabel.textColor = theme.textPrimary
        titleLabel.isSelectable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor,
                                                constant: Metrics.space3),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                 constant: -Metrics.space3),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor,
                                            constant: Metrics.space2),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor,
                                               constant: -Metrics.space2),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        titleLabel.font = theme.fontBody
        titleLabel.textColor = theme.textPrimary
        restyle()
    }

    func setSelected(_ selected: Bool, theme: Theme) {
        self.selected = selected
        self.theme = theme
        restyle()
    }

    private func restyle() {
        let fill: NSColor
        if selected {
            fill = theme.accentQuiet
        } else if hovering {
            fill = theme.surfaceAlt
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (selected ? theme.accent.withAlphaComponent(0.55) : .clear).cgColor
        dot.applyTheme(theme, selected: selected)
        setAccessibilityValue(selected ? 1 : 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class SelectionDot: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme, selected: Bool) {
        layer?.backgroundColor = (selected ? theme.accent : NSColor.clear).cgColor
        layer?.borderColor = (selected ? theme.accent : theme.border).cgColor
    }
}

// MARK: - Toggle row

/// A switch with its explanation underneath. The caption spans the row so it
/// can wrap, while the switch keeps its fixed place at the trailing edge.
private final class ToggleRowView: NSView {
    private let titleLabel: NSTextField
    private let captionLabel: NSTextField
    private let control: NSSwitch

    init(title: String, caption: String, theme: Theme, control: NSSwitch) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.captionLabel = Ink.caption(caption, theme)
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = theme.fontBody
        titleLabel.textColor = theme.textPrimary
        titleLabel.isSelectable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(control)
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor,
                                                 constant: -Metrics.space3),

            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor,
                                              constant: Metrics.space2),
            control.bottomAnchor.constraint(lessThanOrEqualTo: captionLabel.topAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        titleLabel.font = theme.fontBody
        titleLabel.textColor = theme.textPrimary
        captionLabel.font = theme.fontSmall
        captionLabel.textColor = theme.textSecondary
    }
}
