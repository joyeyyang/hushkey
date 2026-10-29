import AppKit
import UniformTypeIdentifiers
import VoiceInputKit

/// The app's main window: a persistent control panel with five tabs
/// (轉錄 / 歷史 / 關鍵字 / 模型 / 設定). It stays open until the user closes it;
/// closing it does not quit the app (the menu-bar icon reopens it).
///
/// The window is built from the pieces in `DesignKit`: a header that carries the
/// app's name and the live model state, a row of tab pills, and cards on the
/// window's paper. It deliberately has no `NSTabView` chrome and no bezel
/// borders — those are what made the old build look like a prototype.
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
    /// Announces the chosen translation direction ("auto" / "off" / "en" / "zh").
    var onTranslateChange: ((String) -> Void)?
    /// Announces the cleanup's register ("casual" / "normal" / "formal").
    var onToneChange: ((String) -> Void)?
    /// Whether meeting mode also records what the Mac is playing.
    var onSystemAudioChange: ((Bool) -> Void)?
    /// Paste a line picked out of the history into whatever app is in front.
    var onPasteHistory: ((String) -> Void)?
    /// Clears a stale Accessibility row and asks the system again.
    var onResetPermission: (() -> Void)?
    /// Transcribe an audio file the user picked or dropped.
    var onImportAudio: ((URL) -> Void)?
    var onQuit: (() -> Void)?
    var onExportSettingsChange: ((ExportSettings) -> Void)?
    var onExportNow: (() -> Void)?
    var onRecheckPermission: (() -> Void)?

    // MARK: - Chrome

    private var theme = ThemeCatalog.current
    private let tabView = NSTabView()
    private var tabStrip: TabStrip!
    private var statusPill: StatusPill!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!

    /// Every button drawn by `DesignKit`, re-coloured on a theme change.
    private var themedButtons: [ThemedButton] = []
    /// Cards, so the permission banner can swap its tint back.
    private var cards: [ThemeCard] = []
    /// Closures that re-apply a colour when the palette changes. A label's role
    /// (primary / secondary / danger) is decided where it is created, so the
    /// refresh is registered next to it instead of in one giant switch.
    private var refreshers: [() -> Void] = []

    // MARK: - Tabs

    private lazy var modelManager = ModelManagerView(theme: theme)
    private lazy var historyView = HistoryTabView(theme: theme, history: history)
    private lazy var settingsView = SettingsTabView(theme: theme)

    // 轉錄 tab
    private let dictationButton = ThemedButton("開始聽寫", kind: .primary, theme: ThemeCatalog.current)
    private let meetingButton = ThemedButton("開始會議", kind: .secondary, theme: ThemeCatalog.current)
    private let importButton = ThemedButton("匯入音檔…", kind: .secondary, theme: ThemeCatalog.current)
    private let folderButton = ThemedButton("開啟會議資料夾", kind: .ghost, theme: ThemeCatalog.current)

    private let permissionCard = ThemeCard(theme: ThemeCatalog.current)
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = ThemedButton("開啟「輔助使用」設定", kind: .primary, theme: ThemeCatalog.current)
    private let recheckButton = ThemedButton("我已經開好了", kind: .secondary, theme: ThemeCatalog.current)
    private let resetPermissionButton = ThemedButton("重設權限（清掉舊紀錄）", kind: .ghost, theme: ThemeCatalog.current)

    private let transcriptView = NSTextView()
    /// 修改的提示詞: the instruction the user types, the region they pick, and the
    /// button that applies it. The app already had the SPOKEN path (say the
    /// instruction, the classifier applies it); this is the same core call with
    /// the instruction typed instead of spoken, because the classifier does not
    /// catch every sentence and a missed one looked like the feature was absent.
    private let editField = NSTextField()
    private let editRegionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 輕鬆／一般／正式, the same three registers as 設定 › 語氣.
    ///
    /// It is here as well as in Settings because the moment a user wants a
    /// different register is the moment they are rewriting a sentence; making
    /// them leave this card to change it is how a setting goes unused. Both
    /// controls read and write `settings.tone` -- neither owns the value, so
    /// they cannot disagree.
    private let editToneControl = NSSegmentedControl(
        labels: ["輕鬆", "一般", "正式"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let editButton = ThemedButton("執行修改", kind: .secondary, theme: ThemeCatalog.current)
    /// Instruction, region, the draft the region was measured against, and the
    /// selected range when the region is a selection. The draft travels with the
    /// range so the two cannot disagree about what "選取範圍" is.
    var onManualEdit: ((String, PromptEditRegion, String, Range<String.Index>?) -> Void)?
    private let transcriptScroll = NSScrollView()
    private let copyTranscriptButton = ThemedButton("複製", kind: .secondary, theme: ThemeCatalog.current)
    /// What is actually in the transcript card. Kept separately from the text
    /// view's string because the empty state draws a placeholder into it.
    private var transcriptText = ""
    private var recordCaption: NSTextField!

    // 關鍵字 tab
    private let keywordField = NSTextField()
    private let addKeywordButton = ThemedButton("新增", kind: .secondary, theme: ThemeCatalog.current)
    private let keywordTable = NSTableView()

    init(keywords: Keywords, history: HistoryStore) {
        self.keywords = keywords
        self.history = history
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.title = "Hushkey"
        // A transparent title bar keeps the traffic lights where macOS expects
        // them while letting the window's own paper run to the top edge.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        minSize = NSSize(width: 520, height: 560)
        buildUI()
        syncSettings()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API used by AppController

    func updateState(dictating: Bool, meeting: Bool) {
        dictationButton.titleText = dictating ? "停止聽寫" : "開始聽寫"
        meetingButton.titleText = meeting ? "停止會議" : "開始會議"
        dictationButton.setKind(meeting ? .secondary : .primary)
        meetingButton.setSelected(meeting)
    }

    /// The header pill: what the engine is doing, in colour.
    ///
    /// The strings come from `AppController` and already read well aloud
    /// ("模型：載入中…"), so the kind is inferred from the words rather than
    /// plumbed through as a second argument every call site would have to know.
    func setStatus(_ text: String) {
        let kind: StatusPill.Kind
        if text.contains("失敗") || text.contains("錯誤") {
            kind = .error
        } else if text.contains("就緒") {
            kind = .ok
        } else if text.contains("載入") || text.contains("準備") || text.contains("下載") || text.contains("辨識") {
            kind = .warn
        } else {
            kind = .neutral
        }
        statusPill.set(text: text, kind: kind)
    }

    /// Shows or hides the Accessibility-permission banner. Without that
    /// permission the app can only copy the text, not paste it.
    func setAccessibilityGranted(_ granted: Bool) {
        permissionLabel.stringValue = granted ? ""
            : "系統回報尚未取得「輔助使用」權限，所以只能把文字放進剪貼簿，不能自動貼上。\n"
            + "到「隱私權與安全性 → 輔助使用」用「＋」加入 /Applications/OfflineVoiceAssistant.app 並打開開關。\n"
            + "若開關看起來已經是開的、這裡卻仍說沒有，那一列是舊版本留下的（授權綁在程式簽章上）。按「重設權限」清掉舊紀錄再加入即可。"
        permissionCard.isHidden = granted
        for button in [permissionButton, recheckButton, resetPermissionButton] {
            button.isHidden = granted
        }
    }

    func setTranscript(_ text: String) {
        transcriptText = text
        copyTranscriptButton.isEnabled = !text.isEmpty
        transcriptView.string = text
        styleTranscript()
        transcriptView.scrollToBeginningOfDocument(nil)
    }

    /// Re-reads the store; called after a transcript is saved.
    func refreshHistory() {
        historyView.refresh()
    }

    // MARK: - UI construction

    private func buildUI() {
        let root = NSView()
        root.wantsLayer = true
        contentView = root

        let header = buildHeader()
        tabStrip = TabStrip(titles: ["轉錄", "歷史", "關鍵字", "模型", "設定"], theme: theme)
        tabStrip.onSelect = { [weak self] index in
            guard let self, self.tabView.tabViewItems.indices.contains(index) else { return }
            self.tabView.selectTabViewItem(at: index)
        }

        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        let transcribe = buildTranscribeTab()
        transcribe.acceptAudioFileDrops { [weak self] url in self?.onImportAudio?(url) }
        tabView.addTabViewItem(makeItem("轉錄", transcribe))
        tabView.addTabViewItem(makeItem("歷史", historyView))
        tabView.addTabViewItem(makeItem("關鍵字", buildKeywordsTab()))
        tabView.addTabViewItem(makeItem("模型", modelManager))
        tabView.addTabViewItem(makeItem("設定", settingsView))

        root.addSubview(header)
        root.addSubview(tabStrip)
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.space5),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Metrics.space5),
            tabStrip.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.space4),

            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.space5),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.space5),
            tabView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: Metrics.space4),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.space4),
        ])
    }

    /// Name, one line of intent, and the live state — the three things a person
    /// wants before touching anything.
    private func buildHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = Ink.title("Hushkey", theme)
        subtitleLabel = Ink.small("全程離線 · 音訊與逐字稿不會離開這台電腦", theme)
        let text = NSStackView.column([titleLabel, subtitleLabel], spacing: 2)
        statusPill = StatusPill(theme: theme)
        statusPill.set(text: "模型：尚未載入", kind: .neutral)

        let line = Hairline(theme: theme)
        header.addSubview(text)
        header.addSubview(statusPill)
        header.addSubview(line)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 58),
            text.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Metrics.space5),
            text.topAnchor.constraint(equalTo: header.topAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: statusPill.leadingAnchor, constant: -Metrics.space3),
            statusPill.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Metrics.space5),
            statusPill.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Metrics.space5),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -Metrics.space5),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        refreshers.append { [weak self] in
            guard let self else { return }
            self.titleLabel.textColor = self.theme.textPrimary
            self.subtitleLabel.textColor = self.theme.textSecondary
            line.applyTheme(self.theme)
        }
        return header
    }

    private func makeItem(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    /// Wraps a tab's content in a scroll view.
    ///
    /// The permission banner and the settings form both grow taller than a small
    /// window; clipping the bottom was the old failure mode, so every tab that
    /// can grow is scrollable and stretches to fill when there is room.
    private func scrolled(_ content: NSView, inset: CGFloat = 0) -> NSView {
        let host = NSView()
        let scroll = TopAnchoredScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            // A couple of points of breathing room at the top: a wrapping label
            // pinned to y = 0 has its ascenders clipped by the scroll edge.
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: Metrics.space2),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Metrics.space2),
        ])
        return host
    }

    /// A card with padding, sized by its content.
    private func card(_ body: NSView) -> ThemeCard {
        let card = ThemeCard(theme: theme)
        card.embed(body)
        cards.append(card)
        return card
    }

    private func button(_ button: ThemedButton, _ action: Selector) {
        button.target = self
        button.action = action
        themedButtons.append(button)
    }

    private func buildTranscribeTab() -> NSView {
        // 錄音
        recordCaption = Ink.caption(
            "按 Option+Space 開始／停止聽寫，結果會出現在浮動視窗：Enter 貼上，Esc 只關閉視窗。",
            theme
        )
        let recordHeading = Ink.heading("錄音", theme)
        refreshers.append { [weak self] in
            guard let self else { return }
            recordHeading.textColor = self.theme.textPrimary
            self.recordCaption.textColor = self.theme.textSecondary
        }

        dictationButton.makeLarge()
        meetingButton.makeLarge()
        button(dictationButton, #selector(didTapDictation))
        button(meetingButton, #selector(didTapMeeting))
        button(importButton, #selector(didTapImport))
        button(folderButton, #selector(didTapFolder))

        let mainActions = NSStackView.row([dictationButton, meetingButton], spacing: Metrics.space2)
        let quietActions = NSStackView.row([importButton, folderButton], spacing: Metrics.space2)
        let recordBody = NSStackView.column([recordHeading, recordCaption, mainActions, quietActions], spacing: Metrics.space3)
        let recordCard = card(recordBody)

        // 權限
        permissionLabel.font = NSFont.systemFont(ofSize: 12)
        permissionLabel.stringValue = ""
        button(permissionButton, #selector(didTapPermission))
        button(recheckButton, #selector(didTapRecheckPermission))
        button(resetPermissionButton, #selector(didTapResetPermission))
        resetPermissionButton.toolTip = "執行 tccutil reset 清掉這個 App 的輔助使用紀錄，再重新跳出系統權限對話框"
        let permissionNote = Ink.caption("授權綁在程式簽章上，換版本後舊紀錄會失效。", theme)
        let permissionButtons = NSStackView.row([permissionButton, recheckButton, resetPermissionButton],
                                                spacing: Metrics.space2)
        let permissionBody = NSStackView.column([permissionLabel, permissionButtons, permissionNote],
                                                spacing: Metrics.space2)
        permissionCard.embed(permissionBody, inset: Metrics.space4)
        permissionCard.isHidden = true
        cards.append(permissionCard)
        for view in [permissionButton, recheckButton, resetPermissionButton] {
            view.isHidden = true
        }
        refreshers.append { [weak self] in
            guard let self else { return }
            self.permissionLabel.textColor = self.theme.danger
            permissionNote.textColor = self.theme.textSecondary
            self.permissionCard.setFill(self.theme.warning.withAlphaComponent(self.theme.isDark ? 0.16 : 0.10))
        }

        // 逐字稿
        let transcriptHeading = Ink.heading("最近一次結果", theme)
        let transcriptHint = Ink.small("保留原始文字，可用滑鼠選取複製", theme)
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.scrollerStyle = .overlay
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 14, height: 12)
        transcriptView.minSize = NSSize(width: 0, height: 0)
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptScroll.documentView = transcriptView

        button(copyTranscriptButton, #selector(didTapCopyTranscript))
        copyTranscriptButton.isEnabled = false
        copyTranscriptButton.toolTip = "把整段結果放進剪貼簿（也可以在文字上選取後按 Cmd+C）"
        let transcriptHeader = NSStackView.row([transcriptHeading], spacing: Metrics.space2)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        transcriptHeader.addArrangedSubview(spacer)
        transcriptHeader.addArrangedSubview(transcriptHint)
        transcriptHeader.addArrangedSubview(copyTranscriptButton)
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let transcriptBody = NSStackView.column([transcriptHeader, transcriptScroll], spacing: Metrics.space3)
        let transcriptCard = card(transcriptBody)
        refreshers.append { [weak self] in
            guard let self else { return }
            transcriptHeading.textColor = self.theme.textPrimary
            transcriptHint.textColor = self.theme.textSecondary
            self.styleTranscript()
        }

        // 修改的提示詞
        let editHeading = Ink.heading("修改的提示詞", theme)
        let editCaption = Ink.caption(
            "把要 AI 怎麼改寫成一句話，再選要改哪一段。語氣和設定頁共用同一個值，只影響「AI 整理」。",
            theme
        )
        editField.placeholderString = "例：把第二點改到禮拜五／改短一點"
        editField.font = NSFont.systemFont(ofSize: 13)
        editField.setContentHuggingPriority(.init(1), for: .horizontal)
        editField.target = self
        editField.action = #selector(didTapManualEdit)
        editRegionPopUp.font = NSFont.systemFont(ofSize: 12)
        editRegionPopUp.addItem(withTitle: "整段")
        editRegionPopUp.addItem(withTitle: "選取範圍")
        editToneControl.segmentStyle = .rounded
        editToneControl.controlSize = .small
        editToneControl.font = NSFont.systemFont(ofSize: 11)
        editToneControl.target = self
        editToneControl.action = #selector(didChangeEditTone)
        editToneControl.setToolTip("整理要用的語域；和設定頁的「語氣」是同一個值", forSegment: 0)
        editToneControl.setToolTip("整理要用的語域；和設定頁的「語氣」是同一個值", forSegment: 1)
        editToneControl.setToolTip("整理要用的語域；和設定頁的「語氣」是同一個值", forSegment: 2)
        editToneControl.setAccessibilityLabel("語氣")
        button(editButton, #selector(didTapManualEdit))
        let editRow = NSStackView.row(
            [editField, editRegionPopUp, editToneControl, editButton], spacing: Metrics.space2
        )
        let editBody = NSStackView.column([editHeading, editCaption, editRow], spacing: Metrics.space2)
        let editCard = card(editBody)
        refreshers.append { [weak self] in
            guard let self else { return }
            editHeading.textColor = self.theme.textPrimary
            editCaption.textColor = self.theme.textSecondary
            self.editField.textColor = self.theme.textPrimary
        }

        let column = NSStackView.column([recordCard, permissionCard, transcriptCard, editCard], spacing: Metrics.space4)
        let host = scrolled(column)
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalTo: host.widthAnchor),
            recordCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            permissionCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            transcriptCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            editCard.widthAnchor.constraint(equalTo: column.widthAnchor),
            transcriptScroll.widthAnchor.constraint(equalTo: transcriptCard.widthAnchor, constant: -2 * Metrics.space4),
        ])
        return host
    }

    private func styleTranscript() {
        // The view is selectable, so a drag + Cmd+C works; the button is for the
        // common case where the user just wants the whole result on the
        // pasteboard without hunting for a selection.
        copyTranscriptButton.isEnabled = !transcriptText.isEmpty
        editButton.isEnabled = !transcriptText.isEmpty
        refreshEditRegions()
        transcriptView.string = transcriptText
        if transcriptText.isEmpty {
            transcriptView.textStorage?.setAttributedString(NSAttributedString(
                string: "還沒有一筆結果。按「開始聽寫」，或把音檔拖進這個視窗。",
                attributes: [
                    .font: theme.fontBody,
                    .foregroundColor: theme.textSecondary.withAlphaComponent(0.7),
                ]
            ))
        }
        transcriptView.backgroundColor = .clear
        transcriptView.textColor = theme.textPrimary
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.32
        transcriptView.defaultParagraphStyle = paragraph
        transcriptView.typingAttributes = [
            .font: theme.fontBody,
            .foregroundColor: theme.textPrimary,
            .paragraphStyle: paragraph,
        ]
    }

    private func buildKeywordsTab() -> NSView {
        let info = Ink.caption(
            "關鍵字（人名、專案代號等）會提示 AI 別寫錯。輸入後按 Enter 或「新增」；在清單上雙擊可刪除。",
            theme
        )
        refreshers.append { [weak self] in
            guard let self else { return }
            info.attributedStringValue = NSAttributedString(
                string: info.stringValue,
                attributes: [
                    .font: self.theme.fontSmall,
                    .foregroundColor: self.theme.textSecondary,
                ]
            )
        }

        keywordField.placeholderString = "例如：李明宏、OVC 專案"
        keywordField.font = theme.fontBody
        keywordField.isBezeled = false
        keywordField.drawsBackground = false
        keywordField.focusRingType = .none
        keywordField.delegate = self
        keywordField.translatesAutoresizingMaskIntoConstraints = false

        let fieldCard = ThemeCard(theme: theme, fill: theme.surfaceAlt)
        fieldCard.embed(keywordField, inset: Metrics.space2)
        fieldCard.heightAnchor.constraint(equalToConstant: 34).isActive = true
        cards.append(fieldCard)
        refreshers.append { [weak self] in
            guard let self else { return }
            fieldCard.setFill(self.theme.surfaceAlt)
            fieldCard.applyTheme(self.theme)
            self.keywordField.textColor = self.theme.textPrimary
        }

        button(addKeywordButton, #selector(didTapAddKeyword))
        let entryRow = NSStackView.row([fieldCard, addKeywordButton], spacing: Metrics.space2)
        fieldCard.setContentHuggingPriority(.init(1), for: .horizontal)
        fieldCard.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        keywordTable.headerView = nil
        keywordTable.rowHeight = 32
        keywordTable.backgroundColor = .clear
        keywordTable.usesAlternatingRowBackgroundColors = false
        keywordTable.selectionHighlightStyle = .regular
        keywordTable.delegate = self
        keywordTable.dataSource = self
        keywordTable.target = self
        keywordTable.doubleAction = #selector(didTapDeleteKeyword)
        keywordTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        keywordTable.style = .plain
        keywordTable.gridStyleMask = .solidHorizontalGridLineMask
        keywordTable.gridColor = theme.border
        keywordTable.intercellSpacing = NSSize(width: 0, height: 0)
        keywordTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword")))

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.scrollerStyle = .overlay
        tableScroll.documentView = keywordTable
        keywordTable.autoresizingMask = [.width]
        keywordTable.sizeLastColumnToFit()
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let listCard = card(tableScroll)
        refreshers.append { [weak self] in
            guard let self else { return }
            self.keywordTable.backgroundColor = .clear
            self.keywordTable.gridColor = self.theme.border
            self.keywordTable.reloadData()
        }

        let column = NSStackView.column([info, entryRow, listCard], spacing: Metrics.space3)
        let host = NSView()
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            column.topAnchor.constraint(equalTo: host.topAnchor, constant: Metrics.space2),
            column.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
            entryRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            listCard.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        return host
    }

    // MARK: - Settings

    /// Every settings change is forwarded from the settings tab, which owns the
    /// controls but not the persistence: a value is only real once this window
    /// has written it.
    private func wireSettings() {
        settingsView.onThemeChange = { [weak self] code in
            UserDefaults.standard.set(code, forKey: "settings.theme")
            ThemeCatalog.setCurrent(id: code)
            self?.onThemeChange?()
        }
        settingsView.onHotkeyChange = { [weak self] spec in
            UserDefaults.standard.set(spec, forKey: "settings.hotkey")
            self?.onHotkeyChange?(spec)
        }
        settingsView.onTranslateChange = { [weak self] code in
            UserDefaults.standard.set(code, forKey: "settings.translate")
            self?.onTranslateChange?(code)
        }
        settingsView.onToneChange = { [weak self] code in
            UserDefaults.standard.set(code, forKey: Self.toneKey)
            // Two controls, one value: the card in this window shows the same
            // three registers, so a change made in Settings has to move it.
            self?.syncEditTone(code)
            self?.onToneChange?(code)
        }
        settingsView.onPolishChange = { [weak self] enabled in self?.onPolishChange?(enabled) }
        settingsView.onConfirmChange = { [weak self] confirm in self?.onConfirmChange?(confirm) }
        settingsView.onSystemAudioChange = { [weak self] enabled in self?.onSystemAudioChange?(enabled) }
        settingsView.onExportSettingsChange = { [weak self] settings in self?.onExportSettingsChange?(settings) }
        settingsView.onExportNow = { [weak self] in self?.onExportNow?() }
        settingsView.onQuit = { [weak self] in self?.onQuit?() }

        historyView.onPaste = { [weak self] entry in self?.onPasteHistory?(entry.polished) }
        historyView.onCopy = { [weak self] entry in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(entry.polished, forType: .string)
            self?.setStatus("已複製到剪貼簿")
        }
    }

    private func syncSettings() {
        wireSettings()
        settingsView.syncFromDefaults()
        syncEditTone(UserDefaults.standard.string(forKey: Self.toneKey) ?? "normal")
        keywordTable.reloadData()
    }

    // MARK: - Theme

    /// Follows the chosen palette. Every designed part is re-coloured in place so
    /// the window does not lose its scroll position or selection.
    func applyTheme(_ theme: Theme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        backgroundColor = theme.background
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = theme.background.cgColor

        statusPill.applyTheme(theme)
        tabStrip.applyTheme(theme)
        themedButtons.forEach { $0.applyTheme(theme) }
        cards.forEach { $0.applyTheme(theme) }
        refreshers.forEach { $0() }
        historyView.applyTheme(theme)
        settingsView.applyTheme(theme)
        modelManager.applyTheme(theme)
        styleTranscript()
    }

    /// Renders the whole window content (header, tab strip and the open tab).
    func snapshotWindow(to url: URL) -> Bool {
        guard let view = contentView, view.bounds.width > 1 else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Renders one tab offscreen and writes it as a PNG.
    ///
    /// Offscreen on purpose: the visual self-tests run headless, so a tab that
    /// only looks right while the window is on screen would never be checked.
    func snapshotTab(_ label: String, to url: URL) -> Bool {
        guard let tab = contentView?.subviews.compactMap({ $0 as? NSTabView }).first,
              let item = tab.tabViewItems.first(where: { $0.label == label }),
              let view = item.view else { return false }
        tab.selectTabViewItem(item)
        if let index = tab.tabViewItems.firstIndex(of: item) {
            tabStrip.setSelectedIndex(index, notify: false)
        }
        // A tab may be a scroll view whose content is taller than the window --
        // the settings page is. Snapshot the DOCUMENT view then: a page cut off at
        // the fold hides exactly the card a reviewer opened the picture for.
        let target: NSView = view.subviews
            .compactMap { $0 as? NSScrollView }
            .first?.documentView ?? view
        target.layoutSubtreeIfNeeded()
        guard target.bounds.width > 1, target.bounds.height > 1,
              let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return false }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    // MARK: - Actions

    @objc private func didTapDictation() { onToggleDictation?() }
    @objc private func didTapMeeting() { onToggleMeeting?() }
    @objc private func didTapFolder() { onOpenMeetingsFolder?() }

    /// A file picker next to drag-and-drop: the drop area is the tab's own
    /// background, which the transcript view covers, so the button is the path
    /// that always works.
    @objc private func didTapImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.message = "選一個音檔，逐字稿會在浮動視窗裡出現"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onImportAudio?(url)
    }

    /// Copies the last result. Pasting it into another app is then the user's
    /// own Cmd+V, which needs no Accessibility permission at all.
    /// Rebuilds the region list from the draft on screen.
    ///
    /// The line items are the CORE's numbering (`PromptEditRegion.lines` follows
    /// the core's `numbered_items`), so "第 3 行" in this menu is the line the
    /// core will edit, not a count of the newlines this view happens to show.
    private func refreshEditRegions() {
        let previous = editRegionPopUp.indexOfSelectedItem
        editRegionPopUp.removeAllItems()
        editRegionPopUp.addItem(withTitle: "整段")
        editRegionPopUp.addItem(withTitle: "選取範圍")
        for (index, line) in PromptEditRegion.lines(of: transcriptText).enumerated() {
            let preview = line.count > 16 ? String(line.prefix(16)) + "…" : line
            editRegionPopUp.addItem(withTitle: "第 \(index + 1) 行：\(preview)")
        }
        if previous >= 0, previous < editRegionPopUp.numberOfItems {
            editRegionPopUp.selectItem(at: previous)
        }
    }

    /// The 修改的提示詞 button. The window owns the draft and the selection, so it
    /// hands both to the app, which owns the engine.
    @objc private func didTapManualEdit() {
        let typed = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            setStatus("先輸入修改的提示詞")
            return
        }
        guard !transcriptText.isEmpty else {
            setStatus("還沒有一筆結果可以修改")
            return
        }
        let index = editRegionPopUp.indexOfSelectedItem
        var region: PromptEditRegion = .whole
        var selection: Range<String.Index>?
        if index == 1 {
            region = .selection
            let ns = transcriptView.selectedRange()
            if ns.length > 0 { selection = Range(ns, in: transcriptText) }
            // Not a silent fallback to the whole draft: "只改我選的那段" must
            // never rewrite the rest.
            guard selection != nil else {
                setStatus("先在逐字稿上選取要改的那一段")
                return
            }
        } else if index >= 2 {
            region = .line(index - 1)
        }
        onManualEdit?(typed, region, transcriptText, selection)
    }

    /// The register changed in this card: write the same key the settings card
    /// writes, then tell the controller. The settings card is updated through
    /// `syncEditTone` when the change comes from the other direction.
    @objc private func didChangeEditTone() {
        let code = Self.toneCodes[min(max(editToneControl.selectedSegment, 0), 2)]
        UserDefaults.standard.set(code, forKey: Self.toneKey)
        onToneChange?(code)
    }

    /// Shows the stored register in this card without writing anything back.
    private func syncEditTone(_ code: String) {
        editToneControl.selectedSegment = Self.toneCodes.firstIndex(of: code) ?? 1
    }

    private static let toneKey = "settings.tone"
    /// Casual first, normal in the middle, formal last -- the same order and the
    /// same core strings as the settings card.
    private static let toneCodes = ["casual", "normal", "formal"]

    @objc private func didTapCopyTranscript() {
        guard !transcriptText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcriptText, forType: .string)
        let original = copyTranscriptButton.titleText
        copyTranscriptButton.titleText = "已複製"
        setStatus("已複製逐字稿")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyTranscriptButton.titleText = original
        }
    }

    @objc private func didTapPermission() { TextInjector.requestAccessibility() }
    @objc private func didTapRecheckPermission() { onRecheckPermission?() }
    @objc private func didTapResetPermission() { onResetPermission?() }

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
}

// MARK: - Tab selection

extension MainWindow: NSTabViewDelegate {
    /// Disk state is re-read when the tab is opened, not on a timer: models are
    /// downloaded by this window and deleted outside it, so "what is installed"
    /// is only worth trusting as of the moment the user looked.
    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        guard let item, let index = tabView.tabViewItems.firstIndex(of: item) else { return }
        tabStrip.setSelectedIndex(index, notify: false)
        switch item.identifier as? String {
        case "模型":
            modelManager.reload()
        case "歷史":
            historyView.refresh()
        default:
            break
        }
    }
}

// MARK: - Keyword field

extension MainWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === keywordField else { return }
        didTapAddKeyword()
    }
}

// MARK: - Keyword table

extension MainWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        keywords.all.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard keywords.all.indices.contains(row) else { return nil }
        let cell = NSTextField(labelWithString: keywords.all[row])
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.isEditable = false
        cell.font = theme.fontBody
        cell.alignment = .left
        cell.textColor = theme.textPrimary
        return cell
    }
}
