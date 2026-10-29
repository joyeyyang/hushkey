import AppKit

/// The 歷史 tab: everything the app has transcribed, searchable and pasteable.
///
/// **Why a table and not a stack of rows.** Either was allowed, but history is
/// the one list in this app that grows without bound -- a fortnight of dictation
/// is hundreds of rows, and `HistoryStore` caps it at 500. A stack of views would
/// build every row on every `refresh()`, so this is one `NSTableView` with a clear
/// background, no alternating rows, no system selection paint, and fully custom
/// row views. The table recycles rows as they scroll out of view, so there is no
/// "顯示更多" cap and no truncation of the list: every entry is reachable, and
/// `refresh()` costs the same whether the store holds 3 entries or 500.
final class HistoryTabView: NSView {

    // MARK: - Public API

    /// Paste into the frontmost app. Text injection belongs to the host.
    var onPaste: ((HistoryEntry) -> Void)?
    /// Reported after the entry's text is on the pasteboard. This view has
    /// already written it, so an unwired host still gets a working 複製.
    var onCopy: ((HistoryEntry) -> Void)?

    // MARK: - State

    private var theme: Theme
    private let history: HistoryStore
    /// The rows currently on screen: the store, filtered by the search field.
    private var entries: [HistoryEntry] = []
    private var statusClearTimer: Timer?

    /// Fixed-width, tabular figures so the dates line up down the column.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    // MARK: - Views

    private let searchField = NSSearchField()
    private let countLabel: NSTextField
    private let card: ThemeCard
    private let scrollView = NSScrollView()
    private let listView = HistoryTable()
    private let emptyState: NSStackView
    private let emptyHeading: NSTextField
    private let emptyDetail: NSTextField
    private let statusLabel: NSTextField
    private let actionBar = NSView()
    private let buttons: NSStackView
    private let pasteButton: ThemedButton
    private let copyButton: ThemedButton
    private let deleteButton: ThemedButton
    private let clearAllButton: ThemedButton

    // MARK: - Life cycle

    init(theme: Theme, history: HistoryStore) {
        self.theme = theme
        self.history = history

        let heading = Ink.heading("還沒有紀錄", theme)
        let detail = Ink.caption("每次聽寫完成的內容都會自動存在這裡，可以搜尋、貼回游標處。", theme)
        emptyHeading = heading
        emptyDetail = detail
        emptyState = NSStackView.column([heading, detail],
                                        spacing: Metrics.space2,
                                        alignment: .centerX)

        let paste = ThemedButton("貼到游標處", kind: .primary, theme: theme)
        let copy = ThemedButton("複製", kind: .secondary, theme: theme)
        let trash = ThemedButton("刪除", kind: .ghost, theme: theme)
        let clear = ThemedButton("全部清空", kind: .danger, theme: theme)
        pasteButton = paste
        copyButton = copy
        deleteButton = trash
        clearAllButton = clear
        buttons = NSStackView.row([paste, copy, trash, clear], spacing: Metrics.space2)

        countLabel = Ink.small("", theme)
        statusLabel = Ink.small("", theme)
        card = ThemeCard(theme: theme)

        super.init(frame: .zero)

        buildUI()
        applyTheme(theme)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    /// Re-reads the store with whatever is in the search field.
    ///
    /// Safe at any time: the app calls this when the tab is shown and after a new
    /// transcript is saved, and neither may lose the query the user is typing.
    func refresh() {
        reload()
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor

        card.applyTheme(theme)

        countLabel.font = theme.fontSmall
        countLabel.textColor = theme.textSecondary
        emptyHeading.font = theme.fontHeading
        emptyHeading.textColor = theme.textPrimary
        emptyDetail.font = theme.fontSmall
        emptyDetail.textColor = theme.textSecondary
        statusLabel.font = theme.fontSmall
        statusLabel.textColor = theme.textSecondary
        for button in [pasteButton, copyButton, deleteButton, clearAllButton] {
            button.applyTheme(theme)
        }

        // Row views and cells are recycled, so the visible ones are rebuilt
        // rather than left painted in the previous palette.
        let row = listView.selectedRow
        listView.reloadData()
        if entries.indices.contains(row) {
            listView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        updateActionState()
        syncRowStyles()
    }

    // MARK: - Layout

    private func buildUI() {
        wantsLayer = true

        searchField.placeholderString = "搜尋內容…"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(didSearch)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("搜尋歷史紀錄")

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        column.width = 400
        listView.addTableColumn(column)
        listView.headerView = nil
        listView.rowHeight = 38
        listView.intercellSpacing = .zero
        listView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        listView.backgroundColor = .clear
        listView.usesAlternatingRowBackgroundColors = false
        listView.selectionHighlightStyle = .none
        listView.gridStyleMask = []
        listView.style = .plain
        listView.focusRingType = .none
        listView.allowsEmptySelection = true
        listView.allowsMultipleSelection = false
        listView.usesAutomaticRowHeights = false
        listView.dataSource = self
        listView.delegate = self
        listView.target = self
        listView.doubleAction = #selector(didDoubleClickRow)
        listView.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        listView.onActivate = { [weak self] in self?.pasteSelection() }
        listView.setAccessibilityLabel("歷史紀錄")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = listView
        listView.frame = scrollView.contentView.bounds
        listView.autoresizingMask = [.width]

        // The rows fill the card edge to edge; clipping to its rounded corner is
        // what keeps the first and last row from spilling past the radius.
        card.layer?.masksToBounds = true

        emptyHeading.alignment = .center
        emptyDetail.alignment = .center
        emptyDetail.maximumNumberOfLines = 2

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.isHidden = true

        actionBar.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(pasteButton, #selector(didTapPaste)),
                                 (copyButton, #selector(didTapCopy)),
                                 (deleteButton, #selector(didTapDelete)),
                                 (clearAllButton, #selector(didTapClearAll))] {
            button.target = self
            button.action = action
        }
        // 全部清空 is destructive, so it is pushed away from the three safe ones.
        buttons.setCustomSpacing(Metrics.space5, after: deleteButton)

        addSubview(searchField)
        addSubview(countLabel)
        addSubview(card)
        card.addSubview(scrollView)
        card.addSubview(emptyState)
        actionBar.addSubview(statusLabel)
        actionBar.addSubview(buttons)
        addSubview(actionBar)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space4),
            searchField.widthAnchor.constraint(equalToConstant: 240),

            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.trailingAnchor,
                                                constant: Metrics.space3),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space4),
            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),

            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space4),
            card.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Metrics.space3),
            card.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -Metrics.space3),

            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -1),

            emptyState.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor,
                                                constant: Metrics.space5),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor,
                                                 constant: -Metrics.space5),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 330),

            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space4),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.space4),
            actionBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),

            statusLabel.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: actionBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor,
                                                  constant: -Metrics.space3),

            buttons.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: actionBar.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: actionBar.leadingAnchor),
        ])

        // A floor on the list, not a requirement: on a window too short for it the
        // search row and the actions still win, instead of an unsatisfiable set.
        let minCardHeight = card.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        minCardHeight.priority = .defaultHigh
        minCardHeight.isActive = true
    }

    /// Keeps the one column as wide as the card. `columnAutoresizingStyle` does
    /// the same job once the table has a real width; this covers the first pass,
    /// when the table is still laid out at zero.
    override func layout() {
        super.layout()
        guard let column = listView.tableColumns.first else { return }
        let width = max(scrollView.contentSize.width, column.minWidth)
        if abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    // MARK: - Reading the store

    /// Re-reads the store with the current query.
    ///
    /// `preferredRow` is only for a deletion: the entry is gone, so the slot it
    /// occupied takes the selection instead of leaving a run of deletions to be
    /// re-clicked. Any other reload keeps the selection only if that entry
    /// survived the new filter.
    private func reload(preferredRow: Int? = nil) {
        let previous = selectedEntry
        entries = history.search(searchField.stringValue)
        listView.reloadData()

        if let previous, let index = entries.firstIndex(where: { $0.id == previous.id }) {
            listView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let preferredRow, !entries.isEmpty {
            let index = min(preferredRow, entries.count - 1)
            listView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            listView.scrollRowToVisible(index)
        } else {
            listView.deselectAll(nil)
        }

        updateCount()
        updateEmptyState()
        updateActionState()
        syncRowStyles()
    }

    private var selectedEntry: HistoryEntry? {
        let row = listView.selectedRow
        guard entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    private func select(row: Int) {
        guard entries.indices.contains(row) else { return }
        listView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        listView.scrollRowToVisible(row)
        updateActionState()
        syncRowStyles()
    }

    /// ↑/↓: from the search field this also hands the keyboard to the list, so
    /// typing a query and then arrowing down is one continuous gesture.
    private func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        if let window, window.firstResponder !== listView {
            window.makeFirstResponder(listView)
        }
        let current = listView.selectedRow
        let target: Int
        if current < 0 {
            target = delta > 0 ? 0 : entries.count - 1
        } else {
            target = min(max(current + delta, 0), entries.count - 1)
        }
        select(row: target)
    }

    /// Return, or the 貼到游標處 button.
    private func pasteSelection() {
        guard let entry = selectedEntry else {
            // Nothing is highlighted yet: highlight the newest result rather than
            // pasting text the user has not seen selected.
            if entries.isEmpty { NSSound.beep() } else { select(row: 0) }
            return
        }
        onPaste?(entry)
    }

    private func copySelection() {
        guard let entry = selectedEntry else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.polished, forType: .string)
        showStatus("已複製到剪貼簿。")
        onCopy?(entry)
    }

    private func deleteSelection() {
        guard let entry = selectedEntry else { NSSound.beep(); return }
        let row = listView.selectedRow
        history.remove(id: entry.id)
        reload(preferredRow: row)
    }

    /// Same question, same two answers as the plain-AppKit tab had.
    private func confirmClearAll() {
        let total = history.entries.count
        guard total > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "要清空全部 \(total) 筆歷史紀錄嗎？"
        alert.informativeText = "這個動作無法復原。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.removeAll()
        reload()
    }

    // MARK: - Painting the state

    private func updateCount() {
        let total = history.entries.count
        // Nothing to count: the empty state already says it, and repeating the
        // same sentence in the corner reads as a mistake rather than as metadata.
        countLabel.isHidden = total == 0
        if total == 0 {
            countLabel.stringValue = ""
        } else if entries.count == total {
            countLabel.stringValue = "共 \(total) 筆"
        } else {
            countLabel.stringValue = "找到 \(entries.count) 筆（共 \(total) 筆）"
        }
    }

    private func updateEmptyState() {
        let total = history.entries.count
        emptyState.isHidden = !entries.isEmpty
        guard entries.isEmpty else { return }
        if total == 0 {
            emptyHeading.stringValue = "還沒有紀錄"
            emptyDetail.stringValue = "每次聽寫完成的內容都會自動存在這裡，可以搜尋、貼回游標處。"
        } else {
            emptyHeading.stringValue = "找不到符合的紀錄"
            emptyDetail.stringValue = "換個關鍵字試試，或清掉搜尋看全部 \(total) 筆。"
        }
    }

    private func updateActionState() {
        let hasSelection = selectedEntry != nil
        setEnabled(pasteButton, hasSelection)
        setEnabled(copyButton, hasSelection)
        setEnabled(deleteButton, hasSelection)
        setEnabled(clearAllButton, !history.entries.isEmpty)
    }

    /// `ThemedButton` paints one look only, so a disabled button would still read
    /// as clickable; fading it is what makes "nothing selected" visible.
    private func setEnabled(_ button: ThemedButton, _ enabled: Bool) {
        button.isEnabled = enabled
        button.alphaValue = enabled ? 1 : 0.42
    }

    private func syncRowStyles() {
        let picked = listView.selectedRowIndexes
        let visible = listView.rows(in: listView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<visible.upperBound {
            (listView.rowView(atRow: row, makeIfNecessary: false) as? EntryRow)?
                .set(picked: picked.contains(row))
        }
    }

    private func showStatus(_ text: String) {
        statusClearTimer?.invalidate()
        statusClearTimer = nil
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        guard !text.isEmpty else { return }
        statusClearTimer = Timer.scheduledTimer(timeInterval: 2.6,
                                                target: self,
                                                selector: #selector(clearStatus),
                                                userInfo: nil,
                                                repeats: false)
    }

    @objc private func clearStatus() {
        statusClearTimer = nil
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
    }

    // MARK: - Actions

    @objc private func didSearch() { reload() }
    @objc private func didTapPaste() { pasteSelection() }
    @objc private func didTapCopy() { copySelection() }
    @objc private func didTapDelete() { deleteSelection() }
    @objc private func didTapClearAll() { confirmClearAll() }

    @objc private func didDoubleClickRow() {
        guard entries.indices.contains(listView.clickedRow) else { return }
        onPaste?(entries[listView.clickedRow])
    }

    /// `HistoryEntry` records no speaker, so nothing lights the badge today: a
    /// dictation is by definition the user's own words, and a meeting row does
    /// not say who was talking. The argument is the seam, not dead weight -- the
    /// row and its badge are already painted, so the day the model gains a
    /// `speaker` this is the only line that changes.
    private static func speaker(for entry: HistoryEntry) -> String? {
        return nil
    }
}

// MARK: - Table contents

extension HistoryTabView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("historyRow")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? EntryRow
            ?? EntryRow(theme: theme)
        rowView.identifier = identifier
        rowView.applyTheme(theme)
        rowView.set(picked: listView.selectedRowIndexes.contains(row))
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("historyCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EntryCell
            ?? EntryCell(theme: theme)
        cell.identifier = identifier
        let entry = entries[row]
        cell.render(entry,
                    time: Self.timeFormatter.string(from: entry.date),
                    theme: theme,
                    speaker: Self.speaker(for: entry),
                    showsRule: row < entries.count - 1)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionState()
        syncRowStyles()
    }
}

// MARK: - Keyboard, and arrows from the search field

extension HistoryTabView: NSSearchFieldDelegate {
    /// A single-line search field has no use for ↑/↓ or Return, so they drive the
    /// list instead of moving a caret that cannot go anywhere.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            pasteSelection()
            return true
        }
        return false
    }
}

// MARK: - One row

/// The row's own paint: hover and selection, nothing else. The content lives in
/// `EntryCell`, so re-theming never has to rebuild the table.
private final class EntryRow: NSTableRowView {
    private var theme: Theme
    private var hovering = false
    private var picked = false
    private var tracking: NSTrackingArea?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(picked: Bool) {
        guard self.picked != picked else { return }
        self.picked = picked
        paint()
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        paint()
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
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        paint()
    }

    private func paint() {
        let fill: NSColor
        if picked {
            fill = theme.accentQuiet
        } else if hovering {
            fill = theme.surfaceAlt
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

/// One row's contents: time, text, and the speaker slot.
private final class EntryCell: NSView {
    private let timeLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let badge: SpeakerBadge
    private let rule: Hairline
    private var textToBadge: NSLayoutConstraint!
    private var textToEdge: NSLayoutConstraint!

    init(theme: Theme) {
        badge = SpeakerBadge(theme: theme)
        rule = Hairline(theme: theme)
        super.init(frame: .zero)

        // Tabular digits at 11 pt: one step under the body text, so the date
        // reads as a margin rather than as part of the sentence.
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = theme.textSecondary
        timeLabel.lineBreakMode = .byClipping

        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        // The sentence gives way first: the date column and the badge keep their
        // widths when the window is narrow.
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [timeLabel, textLabel, badge, rule] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        textToBadge = textLabel.trailingAnchor.constraint(equalTo: badge.leadingAnchor,
                                                          constant: -Metrics.space2)
        textToEdge = textLabel.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                         constant: -Metrics.space3)

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            timeLabel.widthAnchor.constraint(equalToConstant: 72),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            textLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor,
                                               constant: Metrics.space2),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        textToEdge.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ entry: HistoryEntry,
                time: String,
                theme: Theme,
                speaker: String?,
                showsRule: Bool) {
        timeLabel.stringValue = time
        timeLabel.textColor = theme.textSecondary
        textLabel.stringValue = entry.preview
        textLabel.font = theme.fontBody
        textLabel.textColor = theme.textPrimary
        // The full text stays reachable when the row truncates it.
        toolTip = entry.preview

        if let speaker {
            badge.set(text: speaker)
            badge.applyTheme(theme)
            badge.isHidden = false
            textToEdge.isActive = false
            textToBadge.isActive = true
        } else {
            badge.isHidden = true
            textToBadge.isActive = false
            textToEdge.isActive = true
        }

        rule.applyTheme(theme)
        rule.isHidden = !showsRule
    }
}

/// The 我 / 對方 tag. Only as wide as its word, tinted with the accent so it reads
/// as a label rather than as another button.
private final class SpeakerBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private var theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(text: String) {
        label.stringValue = text
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        label.textColor = theme.accent
        layer?.backgroundColor = theme.accentQuiet.cgColor
    }
}

/// The list itself.
///
/// ↑/↓ and Return are handled here rather than by `NSTableView`'s own movement,
/// so the search field can forward to the same two methods and the two entry
/// points cannot drift apart.
private final class HistoryTable: NSTableView {
    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:                    // ↓
            onMove?(1)
        case 126:                    // ↑
            onMove?(-1)
        case 36, 76:                 // Return, keypad Enter
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }
}
