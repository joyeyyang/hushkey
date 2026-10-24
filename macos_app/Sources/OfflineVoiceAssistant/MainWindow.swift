import AppKit

/// The app's main window: a single persistent control panel with three tabs
/// (轉錄 / 關鍵字 / 設定). It stays open until the user closes it; closing it does
/// not quit the app (the menu-bar icon reopens it).
final class MainWindow: NSWindow {
    private let keywords: Keywords
    private let history: HistoryStore

    // Callbacks into AppController.
    var onToggleDictation: (() -> Void)?
    var onToggleMeeting: (() -> Void)?
    var onOpenMeetingsFolder: (() -> Void)?
    var onThemeChange: (() -> Void)?
    var onHotkeyChange: ((String) -> Void)?
    var onPolishChange: ((Bool) -> Void)?
    var onConfirmChange: ((Bool) -> Void)?
    /// Announces the chosen translation direction ("off" / "en" / "zh").
    var onTranslateChange: ((String) -> Void)?
    /// Whether meeting mode also records what the Mac is playing.
    var onSystemAudioChange: ((Bool) -> Void)?
    /// Paste a line picked out of the history into whatever app is in front.
    var onPasteHistory: ((String) -> Void)?
    var onQuit: (() -> Void)?

    // 轉錄 tab
    private let statusLabel = NSTextField(labelWithString: "模型：尚未載入")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton(title: "開啟「輔助使用」設定", target: nil, action: nil)
    private let recheckButton = NSButton(title: "我已經開好了，重新檢查", target: nil, action: nil)

    /// Called when the user asks the app to re-read the Accessibility state
    /// (typically right after enabling it in System Settings).
    var onRecheckPermission: (() -> Void)?
    private let dictationButton = NSButton(title: "開始聽寫", target: nil, action: nil)
    private let meetingButton = NSButton(title: "開始會議", target: nil, action: nil)
    private let folderButton = NSButton(title: "開啟會議資料夾", target: nil, action: nil)
    private let hintLabel = NSTextField(wrappingLabelWithString:
        "按 Option+Space 開始／停止聽寫。停止後結果會出現在下方；按 Enter 貼到目前輸入框，按 Esc 取消。")
    private let transcriptView = NSTextView()

    // 關鍵字 tab
    private let keywordField = NSTextField()
    private let addKeywordButton = NSButton(title: "新增", target: nil, action: nil)
    private let keywordTable = NSTableView()

    // 歷史 tab
    private let historySearch = NSSearchField()
    private let historyTable = NSTableView()
    private let historyPasteButton = NSButton(title: "貼到游標處", target: nil, action: nil)
    private let historyCopyButton = NSButton(title: "複製", target: nil, action: nil)
    private let historyDeleteButton = NSButton(title: "刪除", target: nil, action: nil)
    private let historyClearButton = NSButton(title: "全部清空", target: nil, action: nil)
    private let historyInfo = NSTextField(labelWithString: "")
    private var historyFiltered: [HistoryEntry] = []

    // 設定 tab
    private let themePopUp = NSPopUpButton()
    private let translatePopUp = NSPopUpButton()
    private let translateTitles = ["關閉（只整理，不翻譯）", "中文 → 英文", "英文 → 中文"]
    private let translateCodes = ["off", "en", "zh"]
    private let hotkeyField = NSTextField()
    private let polishCheckbox = NSButton(checkboxWithTitle: "用 AI 整理逐字稿（潤飾、去除口頭禪）", target: nil, action: nil)
    private let confirmCheckbox = NSButton(checkboxWithTitle: "貼上前先顯示文字讓我確認（按 Enter 才貼）", target: nil, action: nil)
    private let systemAudioCheckbox = NSButton(checkboxWithTitle: "會議模式同時錄製電腦播放的聲音（對方說話）", target: nil, action: nil)
    private let resetButton = NSButton(title: "重設為預設", target: nil, action: nil)
    private let quitButton = NSButton(title: "結束 Offline Voice Assistant", target: nil, action: nil)
    /// The picker lists "follow the system" first, then every palette by its
    /// own name, so the menu reads like a choice of paper rather than a mode.
    private var themeTitles: [String] { ["跟隨系統"] + ThemeCatalog.all.map(\.name) }
    private var themeCodes: [String] { ["system"] + ThemeCatalog.all.map(\.id) }

    // 設定 tab — 匯出
    private let exportFolderField = NSTextField(labelWithString: "（未選擇）")
    private let exportChooseButton = NSButton(title: "選擇資料夾…", target: nil, action: nil)
    private let exportFormatPopUp = NSPopUpButton()
    private let exportAutoCheckbox = NSButton(
        checkboxWithTitle: "每次結束時自動匯出一份（可指定 Obsidian 資料夾）",
        target: nil, action: nil
    )
    private let exportNowButton = NSButton(title: "匯出最近一次逐字稿…", target: nil, action: nil)
    /// Fired on every change to the export controls, with the whole value so the
    /// app has one place to persist instead of three keys to keep in sync.
    var onExportSettingsChange: ((ExportSettings) -> Void)?
    var onExportNow: (() -> Void)?

    init(keywords: Keywords, history: HistoryStore) {
        self.keywords = keywords
        self.history = history
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Offline Voice Assistant"
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 440, height: 420)
        buildUI()
        syncSettings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API used by AppController

    func updateState(dictating: Bool, meeting: Bool) {
        dictationButton.title = dictating ? "停止聽寫" : "開始聽寫"
        meetingButton.title = meeting ? "停止會議" : "開始會議"
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Shows or hides the Accessibility-permission banner. Without that
    /// permission the app can only copy the text, not paste it.
    func setAccessibilityGranted(_ granted: Bool) {
        permissionLabel.stringValue = granted ? ""
            : "⚠️ 系統回報尚未取得「輔助使用」權限，無法自動貼上（文字只會複製到剪貼簿）。請按下方按鈕開啟設定 →「隱私權與安全性 → 輔助使用」，確認清單中有 OfflineVoiceAssistant 而且開關是開啟的。若剛剛才開啟，請把 App 完全結束再重新打開。"
        permissionLabel.isHidden = granted
        permissionButton.isHidden = granted
        recheckButton.isHidden = granted
    }

    func setTranscript(_ text: String) {
        transcriptView.string = text
        transcriptView.scrollToBeginningOfDocument(nil)
    }

    // MARK: - UI construction

    private func buildUI() {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(makeItem("轉錄", buildTranscribeTab()))
        tabView.addTabViewItem(makeItem("歷史", buildHistoryTab()))
        tabView.addTabViewItem(makeItem("關鍵字", buildKeywordsTab()))
        tabView.addTabViewItem(makeItem("設定", buildSettingsTab()))
        contentView!.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -8),
            tabView.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 8),
            tabView.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor, constant: -8),
        ])
    }

    private func makeItem(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func pin(_ stack: NSStackView, in view: NSView, pinBottom: Bool = true) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
        ]
        if pinBottom {
            constraints.append(stack.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func buildTranscribeTab() -> NSView {
        let view = NSView()
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        for (button, action) in [(dictationButton, #selector(didTapDictation)),
                                 (meetingButton, #selector(didTapMeeting)),
                                 (folderButton, #selector(didTapFolder))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        permissionLabel.font = .systemFont(ofSize: 11)
        permissionLabel.textColor = .systemRed
        permissionLabel.isHidden = true
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(didTapPermission)
        permissionButton.isHidden = true
        recheckButton.bezelStyle = .rounded
        recheckButton.target = self
        recheckButton.action = #selector(didTapRecheckPermission)
        recheckButton.isHidden = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.textContainerInset = NSSize(width: 6, height: 6)
        transcriptView.minSize = NSSize(width: 0, height: 0)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = transcriptView

        let stack = NSStackView(views: [statusLabel, permissionLabel,
                                        permissionButton, recheckButton,
                                        dictationButton, meetingButton, folderButton, hintLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        // The form can be taller than the window -- the permission banner adds a
        // label and two buttons. Scroll it rather than letting AppKit clip the
        // bottom (which is what happened before), and let it stretch to fill the
        // window when there is room to spare.
        let formScroll = NSScrollView()
        formScroll.translatesAutoresizingMaskIntoConstraints = false
        formScroll.hasVerticalScroller = true
        formScroll.autohidesScrollers = true
        formScroll.drawsBackground = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        formScroll.documentView = document
        view.addSubview(formScroll)
        NSLayoutConstraint.activate([
            formScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScroll.topAnchor.constraint(equalTo: view.topAnchor),
            formScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: formScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: formScroll.contentView.heightAnchor),
        ])
        pin(stack, in: document)

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        for full in [statusLabel, permissionLabel, hintLabel, scroll] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return view
    }

    private static let historyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()

    private func buildHistoryTab() -> NSView {
        let view = NSView()
        historyInfo.stringValue = "講過的內容會留在這裡，可以搜尋、重新貼上。"
        historyInfo.font = .systemFont(ofSize: 11)
        historyInfo.textColor = .secondaryLabelColor

        historySearch.placeholderString = "搜尋內容…"
        historySearch.sendsWholeSearchString = false
        historySearch.sendsSearchStringImmediately = true
        historySearch.target = self
        historySearch.action = #selector(didSearchHistory)

        for (button, action) in [(historyPasteButton, #selector(didTapPasteHistory)),
                                 (historyCopyButton, #selector(didTapCopyHistory)),
                                 (historyDeleteButton, #selector(didTapDeleteHistory)),
                                 (historyClearButton, #selector(didTapClearHistory))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }

        historyTable.headerView = nil
        historyTable.rowHeight = 30
        historyTable.usesAlternatingRowBackgroundColors = true
        historyTable.delegate = self
        historyTable.dataSource = self
        historyTable.target = self
        historyTable.doubleAction = #selector(didTapPasteHistory)
        historyTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.width = 116
        timeColumn.minWidth = 116
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.width = 320
        historyTable.addTableColumn(timeColumn)
        historyTable.addTableColumn(textColumn)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = historyTable
        scroll.translatesAutoresizingMaskIntoConstraints = false
        historyTable.frame = NSRect(origin: .zero, size: scroll.contentSize)
        historyTable.autoresizingMask = [.width]

        let buttons = NSStackView(views: [historyPasteButton, historyCopyButton,
                                          historyDeleteButton, historyClearButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [historyInfo, historySearch, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        pin(stack, in: view)

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        for full in [historyInfo, historySearch, scroll, buttons] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        refreshHistory()
        return view
    }

    /// Re-reads the store and reapplies whatever is in the search box.
    func refreshHistory() {
        historyFiltered = history.search(historySearch.stringValue)
        historyTable.reloadData()
        let total = history.entries.count
        if historyFiltered.count == total {
            historyInfo.stringValue = total == 0
                ? "還沒有紀錄。每次聽寫完成的內容都會自動存在這裡。"
                : "共 \(total) 筆，最新的在最上面。雙擊可以貼回游標處。"
        } else {
            historyInfo.stringValue = "找到 \(historyFiltered.count) 筆（共 \(total) 筆）。"
        }
    }

    private var selectedHistoryEntry: HistoryEntry? {
        let row = historyTable.selectedRow
        guard row >= 0, historyFiltered.indices.contains(row) else { return nil }
        return historyFiltered[row]
    }

    private func buildKeywordsTab() -> NSView {
        let view = NSView()
        let info = NSTextField(wrappingLabelWithString:
            "關鍵字（人名、專案代號等）會提示 AI 別寫錯。輸入後按 Enter 或「新增」；在清單上雙擊可刪除。")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor

        keywordField.placeholderString = "例如：李明宏、OVC 專案"
        keywordField.delegate = self
        addKeywordButton.bezelStyle = .rounded
        addKeywordButton.target = self
        addKeywordButton.action = #selector(didTapAddKeyword)
        let row = NSStackView(views: [keywordField, addKeywordButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        keywordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        keywordTable.headerView = nil
        keywordTable.rowHeight = 24
        keywordTable.delegate = self
        keywordTable.dataSource = self
        keywordTable.target = self
        keywordTable.doubleAction = #selector(didTapDeleteKeyword)
        keywordTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword"))
        keywordTable.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = keywordTable
        scroll.translatesAutoresizingMaskIntoConstraints = false
        keywordTable.frame = NSRect(origin: .zero, size: scroll.contentSize)
        keywordTable.autoresizingMask = [.width]
        keywordTable.sizeLastColumnToFit()

        let stack = NSStackView(views: [info, row, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        pin(stack, in: view)

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        for full in [info, row, scroll] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return view
    }

    private func buildSettingsTab() -> NSView {
        let view = NSView()
        let themeLabel = NSTextField(labelWithString: "外觀主題")
        themeLabel.font = .systemFont(ofSize: 13)
        themeLabel.textColor = .secondaryLabelColor
        themePopUp.addItems(withTitles: themeTitles)
        themePopUp.selectItem(at: 0)
        themePopUp.target = self
        themePopUp.action = #selector(didChangeTheme)

        let hotkeyLabel = NSTextField(labelWithString: "啟用熱鍵")
        hotkeyLabel.font = .systemFont(ofSize: 13)
        hotkeyLabel.textColor = .secondaryLabelColor
        hotkeyField.placeholderString = "例如：Option+Space"
        hotkeyField.delegate = self
        hotkeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let translateLabel = NSTextField(labelWithString: "翻譯")
        translateLabel.font = .systemFont(ofSize: 13)
        translateLabel.textColor = .secondaryLabelColor
        translatePopUp.addItems(withTitles: translateTitles)
        translatePopUp.target = self
        translatePopUp.action = #selector(didChangeTranslate)

        let help = NSTextField(wrappingLabelWithString:
            "熱鍵格式：修飾鍵 + 按鍵，例如 Option+Space、Control+Shift+R。\n"
            + "淺色模式為米色底 (#F5F0E6)，深色模式為黑底，跟隨系統則依 macOS 設定。\n"
            + "若 AI 整理結果不理想，可關閉「用 AI 整理逐字稿」，直接使用語音辨識原始結果。\n"
            + "會議模式錄系統音訊需要「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」權限；用喇叭時麥克風可能重複收到對方聲音，戴耳機可避免。")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .tertiaryLabelColor

        polishCheckbox.target = self
        polishCheckbox.action = #selector(didTogglePolish)

        confirmCheckbox.target = self
        confirmCheckbox.action = #selector(didToggleConfirm)

        systemAudioCheckbox.target = self
        systemAudioCheckbox.action = #selector(didToggleSystemAudio)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(didTapReset)

        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(didTapQuit)

        // 匯出
        let exportLabel = NSTextField(labelWithString: "匯出")
        exportLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        exportLabel.textColor = .secondaryLabelColor

        exportFormatPopUp.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        exportFormatPopUp.target = self
        exportFormatPopUp.action = #selector(didChangeExport)

        exportChooseButton.bezelStyle = .rounded
        exportChooseButton.target = self
        exportChooseButton.action = #selector(didTapExportFolder)
        exportFolderField.lineBreakMode = .byTruncatingMiddle
        exportFolderField.textColor = .secondaryLabelColor
        exportFolderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        exportAutoCheckbox.target = self
        exportAutoCheckbox.action = #selector(didChangeExport)

        exportNowButton.bezelStyle = .rounded
        exportNowButton.target = self
        exportNowButton.action = #selector(didTapExportNow)

        let exportRow = NSStackView(views: [exportFormatPopUp, exportChooseButton])
        exportRow.orientation = .horizontal
        exportRow.spacing = 8

        let stack = NSStackView(views: [themeLabel, themePopUp, hotkeyLabel, hotkeyField, help,
                                        translateLabel, translatePopUp,
                                        polishCheckbox, confirmCheckbox, systemAudioCheckbox,
                                        exportLabel, exportRow, exportFolderField,
                                        exportAutoCheckbox, exportNowButton,
                                        resetButton, quitButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        pin(stack, in: view, pinBottom: false)
        for full in [themePopUp, hotkeyField, translatePopUp, help, exportFolderField] {
            full.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return view
    }

    // MARK: - Settings state

    private var selectedTheme: String {
        get {
            let i = themePopUp.indexOfSelectedItem
            return (i >= 0 && i < themeCodes.count) ? themeCodes[i] : "system"
        }
        set { if let i = themeCodes.firstIndex(of: newValue) { themePopUp.selectItem(at: i) } }
    }

    private var selectedTranslate: String {
        get {
            let i = translatePopUp.indexOfSelectedItem
            return (i >= 0 && i < translateCodes.count) ? translateCodes[i] : "off"
        }
        set { if let i = translateCodes.firstIndex(of: newValue) { translatePopUp.selectItem(at: i) } }
    }

    private func syncSettings() {
        let defaults = UserDefaults.standard
        selectedTheme = defaults.string(forKey: "settings.theme") ?? "system"
        selectedTranslate = defaults.string(forKey: "settings.translate") ?? "off"
        hotkeyField.stringValue = defaults.string(forKey: "settings.hotkey") ?? "Option+Space"
        polishCheckbox.state = (defaults.object(forKey: "settings.polish") as? Bool ?? true) ? .on : .off
        confirmCheckbox.state = (defaults.object(forKey: "settings.confirmInsert") as? Bool ?? false) ? .on : .off
        systemAudioCheckbox.state = (defaults.object(forKey: "settings.meetingSystemAudio") as? Bool ?? true) ? .on : .off
        let export = ExportSettings.load()
        exportFolderField.stringValue = export.folder.isEmpty ? "（未選擇）" : export.folder
        exportFolderField.toolTip = export.folder.isEmpty ? nil : export.folder
        if let index = ExportFormat.allCases.firstIndex(of: export.format) {
            exportFormatPopUp.selectItem(at: index)
        }
        exportAutoCheckbox.state = export.autoSave ? .on : .off
        keywordTable.reloadData()
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(selectedTheme, forKey: "settings.theme")
        defaults.set(selectedTranslate, forKey: "settings.translate")
        defaults.set(hotkeyField.stringValue, forKey: "settings.hotkey")
    }

    /// Follows the chosen palette.
    ///
    /// Everything inside is a system control, so setting the window's appearance
    /// is what recolours the text, the fields and the tab chrome; the only colour
    /// of our own is the paper behind them.
    func applyTheme(_ theme: Theme) {
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        backgroundColor = theme.background
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = theme.background.cgColor
    }

    // MARK: - Actions

    @objc private func didTapDictation() { onToggleDictation?() }
    @objc private func didTapMeeting() { onToggleMeeting?() }
    @objc private func didTapFolder() { onOpenMeetingsFolder?() }

    // MARK: History actions

    @objc private func didSearchHistory() { refreshHistory() }

    @objc private func didTapPasteHistory() {
        guard let entry = selectedHistoryEntry else { NSSound.beep(); return }
        onPasteHistory?(entry.polished)
    }

    @objc private func didTapCopyHistory() {
        guard let entry = selectedHistoryEntry else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.polished, forType: .string)
        historyInfo.stringValue = "已複製到剪貼簿。"
    }

    @objc private func didTapDeleteHistory() {
        guard let entry = selectedHistoryEntry else { NSSound.beep(); return }
        history.remove(id: entry.id)
        refreshHistory()
    }

    @objc private func didTapClearHistory() {
        guard !history.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "要清空全部 \(history.entries.count) 筆歷史紀錄嗎？"
        alert.informativeText = "這個動作無法復原。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            history.removeAll()
            refreshHistory()
        }
    }

    @objc private func didTapPermission() { TextInjector.requestAccessibility() }
    @objc private func didTapRecheckPermission() { onRecheckPermission?() }

    @objc private func didTapAddKeyword() {
        let trimmed = keywordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keywords.add(trimmed)
        keywordField.stringValue = ""
        keywordTable.reloadData()
    }

    @objc private func didTapDeleteKeyword() {
        let row = keywordTable.clickedRow
        guard row >= 0 && row < keywords.all.count else { return }
        keywords.remove(keywords.all[row])
        keywordTable.reloadData()
    }

    @objc private func didTogglePolish() {
        onPolishChange?(polishCheckbox.state == .on)
    }

    @objc private func didToggleConfirm() {
        onConfirmChange?(confirmCheckbox.state == .on)
    }

    @objc private func didToggleSystemAudio() {
        onSystemAudioChange?(systemAudioCheckbox.state == .on)
    }

    @objc private func didChangeTranslate() {
        saveSettings()
        onTranslateChange?(selectedTranslate)
    }

    @objc private func didTapQuit() {
        onQuit?()
    }

    // MARK: Export actions

    /// Reads the three controls as one value.
    ///
    /// The folder is taken from the field, not from the panel's last answer, so
    /// the checkboxes cannot save a stale path.
    private var currentExportSettings: ExportSettings {
        let index = exportFormatPopUp.indexOfSelectedItem
        let format = (index >= 0 && index < ExportFormat.allCases.count)
            ? ExportFormat.allCases[index]
            : .markdown
        let folder = exportFolderField.stringValue == "（未選擇）" ? "" : exportFolderField.stringValue
        return ExportSettings(folder: folder, format: format, autoSave: exportAutoCheckbox.state == .on)
    }

    @objc private func didTapExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選擇"
        panel.message = "選擇匯出資料夾（例如 Obsidian vault 裡的某個資料夾）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportFolderField.stringValue = url.path
        exportFolderField.toolTip = url.path
        onExportSettingsChange?(currentExportSettings)
    }

    @objc private func didChangeExport() {
        onExportSettingsChange?(currentExportSettings)
    }

    @objc private func didTapExportNow() {
        onExportNow?()
    }

    @objc private func didChangeTheme() {
        saveSettings()
        ThemeCatalog.setCurrent(id: selectedTheme)
        onThemeChange?()
    }

    @objc private func didTapReset() {
        selectedTheme = "system"
        selectedTranslate = "off"
        hotkeyField.stringValue = "Option+Space"
        polishCheckbox.state = .on
        confirmCheckbox.state = .off
        systemAudioCheckbox.state = .on
        saveSettings()
        didChangeTheme()
        onHotkeyChange?(hotkeyField.stringValue)
        didTogglePolish()
        didToggleConfirm()
        didToggleSystemAudio()
        onTranslateChange?(selectedTranslate)
    }
}

// MARK: - NSTextFieldDelegate

extension MainWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === keywordField {
            didTapAddKeyword()
        } else if field === hotkeyField {
            let value = hotkeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            hotkeyField.stringValue = value
            saveSettings()
            onHotkeyChange?(value)
        }
    }
}

// MARK: - Keyword table

extension MainWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === historyTable { return historyFiltered.count }
        return keywords.all.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === historyTable {
            guard historyFiltered.indices.contains(row) else { return nil }
            let entry = historyFiltered[row]
            let isTime = tableColumn?.identifier.rawValue == "time"
            let cell = NSTextField(labelWithString: isTime
                ? Self.historyFormatter.string(from: entry.date)
                : entry.preview)
            cell.isBezeled = false
            cell.drawsBackground = false
            cell.isEditable = false
            cell.lineBreakMode = .byTruncatingTail
            cell.font = isTime
                ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12.5)
            cell.textColor = isTime ? .secondaryLabelColor : .labelColor
            return cell
        }
        let cell = NSTextField(labelWithString: keywords.all[row])
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        cell.alignment = .left
        cell.textColor = .labelColor
        return cell
    }
}
