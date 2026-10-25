import AppKit

/// The one floating surface for a live session: the capsule's controls with the
/// verbatim transcript underneath them.
///
/// This used to be two windows -- a capsule that showed the recording state and
/// a 逐字稿 sheet that showed what was actually being said -- so one session had
/// two things to move, two Escape handlers and two answers to the same question
/// ("am I still recording?"). They are one window now, stacked in the order the
/// user needs them: the controls they operate, a header naming the session, then
/// the words arriving.
///
/// Non-activating, so it never steals focus from the field the text is going to
/// land in. Shapes:
///   - recording: 朱紅 mic + live ink waveform + 字數 + pause + stop + drag handle,
///                with the live transcript card under it once there is one
///   - display:   a one-line status or the finished text
///   - result:    one line of finished text, with a check
///   - edit:      an editable card, Enter pastes, Escape cancels
///
/// Paper and ink only -- no accent colour except the mic. The window is
/// draggable from anywhere except the controls and the transcript card, and the
/// position is kept.
final class DictationWindow: NSObject {
    /// Borderless panels refuse key focus by default, which would make the
    /// editable field (and thus Enter-to-paste) dead, and would leave Escape and
    /// text selection in the transcript dead too. Force key capability.
    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        /// Escape travels up the responder chain to the window when the
        /// read-only text view does not consume it.
        override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }
    }

    // MARK: Palette

    /// The palette the window draws with.
    ///
    /// Static because the small nested views (`SheetView`, `WaveformView`,
    /// `HandleView`, `CircleButton`) read it directly while drawing. Every one of
    /// them draws on the main thread, and this only changes from `applyTheme` on
    /// that same thread.
    private(set) static var theme: Theme = ThemeCatalog.current

    static var paperTop: NSColor { theme.surface }
    static var paperBottom: NSColor { theme.background }
    static var ink: NSColor { theme.textPrimary }
    static var inkSoft: NSColor { theme.textSecondary }
    static var seal: NSColor { theme.accent }
    static var surfaceAlt: NSColor { theme.surfaceAlt }
    static var hairline: NSColor { theme.border.withAlphaComponent(0.75) }
    static var handleDot: NSColor { theme.border }

    /// Margin left around the sheet inside the window so its shadow has room.
    private static let margin: CGFloat = 10

    enum Mode {
        case recording  // capsule: mic, level, count, stop -- plus the transcript
        case display    // one line of status
        case result     // one line of finished text, with a check
        case edit       // editable, Enter submits
    }

    private var mode: Mode = .display

    private var panel: Panel!
    private var card: SheetView!

    // The control row, which is the capsule minus the transcript.
    private var micView: NSImageView!
    private var divider: NSView!
    private var waveView: WaveformView!
    private var countLabel: NSTextField!
    private var stopButton: CircleButton!
    private var pauseButton: CircleButton!
    private var handleView: HandleView!
    private var statusLabel: NSTextField!

    // The header and the transcript card that the capsule grew.
    private var titleLabel: NSTextField!
    private var statusPill: StatusPill!
    private var copyButton: TextButton!
    private var escapeHint: NSTextField!
    private var bodyCard: NSView!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!

    // The editable body, which is a different surface from the transcript: the
    // transcript is a record of what was said, this is a draft to be corrected.
    private var textField: NSTextField!
    private var hintLabel: NSTextField!

    private var hideWork: DispatchWorkItem?
    /// Pending revert of an in-recording `notice`. Non-nil while one is showing.
    private var noticeWork: DispatchWorkItem?
    private var onSubmit: (() -> Void)?

    /// Escape hides the window. While this is set, a later status update must
    /// not put it back in the user's face -- the point of pressing Escape is
    /// that the window stays gone, not that it blinks. Cleared when a new
    /// recording starts.
    private(set) var dismissedByUser = false
    private var escMonitor: Any?
    /// Escape also has to be caught while our own panel is key, which is what
    /// happens once the transcript has been clicked for a selection: a global
    /// monitor never sees events delivered to this app.
    private var localEscMonitor: Any?

    /// Called when the stop button is clicked.
    var onStop: (() -> Void)?

    /// Called when the pause / resume button is clicked during a recording.
    var onPause: (() -> Void)?

    /// Whether audio is currently being dropped. The window shows it in the
    /// waveform's slot, so the stop button never disappears mid-recording.
    private(set) var isPaused = false

    /// The window can be folded down to a dot during a recording, so it stops
    /// covering whatever the user is reading. Recording continues.
    private var collapsed = false

    // MARK: Transcript bookkeeping

    /// Everything written so far, kept so a theme change can re-colour the body:
    /// the colours live in the attributed runs, not in the text view.
    private var transcriptRendered: [TranscriptSegment] = []
    private var transcriptSpeaker = false
    /// The last segment index written, so a repeated poll cannot double-print.
    private var lastTranscriptIndex = 0
    /// Whether the last append is allowed to scroll. False while the user has
    /// scrolled up to read something, true again when they return to the bottom.
    private var followsTail = true
    /// The resolved height of the transcript card, 0 when it is not on screen.
    /// Re-picked on every mode change and append: this is the number the window
    /// size hangs off.
    private var bodyHeight: CGFloat = 0
    /// The last session state handed to `setStatus`. Kept so resuming a pause
    /// puts the pill back on the state it was in, not on a guess.
    private var sessionStatus = ""

    /// Shared by the speaker prefix and the speech so both runs sit on the same
    /// 1.35 leading, and so a segment's paragraph gap does not depend on which
    /// run ends the line.
    private lazy var paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = Metrics.space2
        return style
    }()

    override init() {
        self.panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the sheet draws its own, soft and warm
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.onEscape = { [weak self] in self?.dismissByUser() }

        card = SheetView()
        card.autoresizingMask = [.width, .height]
        card.margin = Self.margin
        panel.contentView = card

        // MARK: control row

        micView = NSImageView()
        micView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micView.contentTintColor = Self.seal
        micView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        card.addSubview(micView)

        divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.hairline.cgColor
        card.addSubview(divider)

        waveView = WaveformView()
        card.addSubview(waveView)

        countLabel = NSTextField(labelWithString: "")
        countLabel.font = .systemFont(ofSize: 12.5)
        countLabel.textColor = Self.inkSoft
        card.addSubview(countLabel)

        stopButton = CircleButton()
        stopButton.fill = Self.ink
        stopButton.glyph = Self.paperTop
        stopButton.onClick = { [weak self] in self?.onStop?() }
        card.addSubview(stopButton)

        // Unfilled, so it reads as secondary to the stop button: the one filled
        // ink circle in the window is always "end this".
        pauseButton = CircleButton()
        pauseButton.filled = false
        pauseButton.fill = Self.ink
        pauseButton.glyph = Self.ink
        pauseButton.glyphKind = .pause
        pauseButton.onClick = { [weak self] in self?.onPause?() }
        card.addSubview(pauseButton)

        card.onDoubleClick = { [weak self] in self?.toggleCollapsed() }
        collapsed = UserDefaults.standard.bool(forKey: "hud.collapsed")

        handleView = HandleView()
        card.addSubview(handleView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = Self.ink
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        card.addSubview(statusLabel)

        // MARK: header

        // The header only exists while the transcript card does. It carries what
        // the separate 逐字稿 panel used to: which session this is, the state
        // pill, and the two quiet controls (複製 / Esc).
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: Self.theme.fontBody.pointSize, weight: .semibold)
        titleLabel.textColor = Self.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        card.addSubview(titleLabel)

        statusPill = StatusPill(theme: Self.theme)
        statusPill.set(text: "", kind: .neutral)
        // The pill comes from the design kit, but this sheet lays out by frame,
        // not by constraints, so it is switched to frame-driven sizing: without
        // that the engine would own its size while everything around it owns its
        // own.
        statusPill.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(statusPill)

        // Drawn here rather than taken from the design kit, for the same reason
        // `CircleButton` is: this panel is normally not the key window while a
        // recording runs, and a stock `NSButton` spends the first click in a
        // non-key window waking the window instead of pressing itself. The stop
        // button next to it has always worked on the first click, and 複製 is the
        // control the transcript mostly exists for.
        copyButton = TextButton(title: "複製")
        copyButton.toolTip = "把目前看到的逐字稿放進剪貼簿"
        copyButton.isEnabled = false
        copyButton.onClick = { [weak self] in self?.copyTranscript() }
        card.addSubview(copyButton)

        escapeHint = NSTextField(labelWithString: "Esc 關閉")
        escapeHint.font = .systemFont(ofSize: 11)
        escapeHint.textColor = Self.inkSoft
        card.addSubview(escapeHint)

        // MARK: transcript card

        bodyCard = NSView()
        bodyCard.wantsLayer = true
        bodyCard.layer?.cornerRadius = Metrics.radiusMedium
        bodyCard.layer?.borderWidth = 1
        // Clips the scroller and the text off the card's rounded corners.
        bodyCard.layer?.masksToBounds = true
        card.addSubview(bodyCard)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = Self.bodyTextInset
        textView.font = NSFont.systemFont(ofSize: Self.bodySize)
        textView.textColor = Self.ink
        textView.isRichText = true
        // The card's width never changes, so the wrap point is pinned rather than
        // tracked: measuring the body then cannot depend on the height we are
        // about to give it.
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        // A meeting transcript grows past a screenful; laying out only what is
        // visible keeps the tail-following scroll smooth while text streams in.
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Overlay scrollers do not eat the text's width, so the wrap point stays
        // put whether or not the transcript is scrolling.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        bodyCard.addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // MARK: editable body

        textField = NSTextField(wrappingLabelWithString: "")
        textField.font = .systemFont(ofSize: 14)
        textField.textColor = Self.ink
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        card.addSubview(textField)

        hintLabel = NSTextField(labelWithString: "Enter 貼上　·　Esc 取消　·　可直接編輯")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = Self.inkSoft
        card.addSubview(hintLabel)

        // The buttons keep their own clicks by type; the transcript card and the
        // editable field have to be named, or the sheet would drag the window
        // instead of letting the user select a line.
        card.interactiveViews = [bodyCard, textField]

        card.layoutHandler = { [weak self] in self?.layoutContents() }
        applyMode(.display)
        panel.orderOut(nil)
        installEscapeMonitor()
    }

    /// Re-skins the window in place.
    ///
    /// The views were built with fixed colours, so every one that carries a
    /// colour has to be told again; the panel's own appearance is set as well so
    /// the editable field's caret and selection follow the theme instead of
    /// staying dark-on-dark. The transcript body is rebuilt from what was
    /// rendered, because its colours live in attributed runs.
    func applyTheme(_ theme: Theme) {
        DictationWindow.theme = theme
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        micView.contentTintColor = mode == .recording ? Self.seal : Self.ink
        divider.layer?.backgroundColor = Self.hairline.cgColor
        countLabel.textColor = Self.inkSoft
        stopButton.fill = Self.ink
        stopButton.glyph = Self.paperTop
        // Unfilled: only the glyph is drawn, so both colours must be re-set.
        pauseButton.fill = Self.ink
        pauseButton.glyph = Self.ink
        statusLabel.textColor = Self.ink
        textField.textColor = Self.ink
        hintLabel.textColor = Self.inkSoft
        titleLabel.font = NSFont.systemFont(ofSize: theme.fontBody.pointSize, weight: .semibold)
        titleLabel.textColor = Self.ink
        escapeHint.textColor = Self.inkSoft
        statusPill.applyTheme(theme)
        copyButton.needsDisplay = true
        bodyCard.layer?.backgroundColor = theme.surface.cgColor
        bodyCard.layer?.borderColor = theme.border.cgColor
        textView.textColor = Self.ink
        card.needsDisplay = true
        waveView.needsDisplay = true
        handleView.needsDisplay = true
        redrawBody()
    }

    /// Draws the sheet offscreen in its display shape, for a scripted visual
    /// check. Nothing is ordered front, so it never flashes on the user's screen.
    func snapshotPreview(text: String, to url: URL) {
        applyMode(.display)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        layoutContents()
        render(to: url)
    }

    /// Offscreen render of the recording window in each of its states, so the
    /// pause button and the folded dot can be looked at without recording
    /// anything.
    func snapshotRecording(to url: URL, paused: Bool = false, folded: Bool = false) {
        collapsed = folded
        applyMode(.recording)
        waveView.reset()
        for level in [0.35, 0.62, 0.44, 0.78, 0.51, 0.33, 0.6, 0.41, 0.72] {
            waveView.push(CGFloat(level))
        }
        countLabel.stringValue = "42 字"
        if paused { setPaused(true) }
        layoutContents()
        render(to: url)
    }

    /// Offscreen render of the merged shape: the live controls with the verbatim
    /// transcript card under them. This is the picture the whole rewrite is
    /// about, so it is the one the self-test has to produce.
    func snapshotTranscript(
        to url: URL,
        title: String,
        status: String,
        segments: [TranscriptSegment],
        showSpeaker: Bool = true
    ) {
        // Unfolded, whatever the user's saved preference says: a dot is not the
        // shape under review.
        collapsed = false
        begin(title: title, status: status, show: false)
        applyMode(.recording)
        for level in [0.35, 0.62, 0.44, 0.78, 0.51, 0.33, 0.6, 0.41, 0.72] {
            waveView.push(CGFloat(level))
        }
        countLabel.stringValue = "42 字"
        append(segments, showSpeaker: showSpeaker)
        render(to: url)
    }

    /// Offscreen render of the confirm-before-insert card. The editable body is
    /// a different surface from the transcript, and it has to survive the merge.
    func snapshotEdit(to url: URL, text: String) {
        applyMode(.edit)
        textField.stringValue = text
        layoutContents()
        render(to: url)
    }

    /// Offscreen render of the finished line with its check, over whatever
    /// transcript is already in the card -- the shape the window is left in for
    /// the couple of seconds after a paste.
    func snapshotResult(to url: URL, text: String) {
        applyMode(.result)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        layoutContents()
        render(to: url)
    }

    private func render(to url: URL) {
        card.layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Escape closes the window and nothing else.
    ///
    /// The window is a non-activating panel, so normally it is not the key window
    /// and a local key monitor would never see the keystroke -- a global monitor
    /// does, and that is allowed here because the app already requires
    /// Accessibility permission to paste. A global monitor cannot consume the
    /// event, so the Escape still reaches whatever app the user was typing in; we
    /// only hide our own window.
    ///
    /// The local monitor is the other half, and it is new with the merge: the
    /// transcript is there to be selected, and clicking it makes this panel key,
    /// at which point the global monitor goes blind (it only observes other
    /// apps). Both paths end in the same place.
    ///
    /// Deliberately NOT wired to `onStop`: Escape is "get this out of my sight",
    /// not "stop recording". Recording, the audio buffer, the recognition and the
    /// finished result are all untouched, and a pause is a separate control.
    private func installEscapeMonitor() {
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel.isVisible else { return }
            self.dismissByUser()
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isVisible, self.panel.isKeyWindow else {
                return event
            }
            self.dismissByUser()
            return nil
        }
    }

    /// Hides the window until the next recording starts.
    func dismissByUser() {
        dismissedByUser = true
        hide()
    }

    /// Re-arms the window for a session that is about to start, so an error or
    /// permission prompt in that session is allowed to appear even if the
    /// previous one was dismissed with Escape.
    func allowShowingAgain() {
        dismissedByUser = false
    }

    deinit {
        // The monitors outlive nothing: they hold no reference to us, but leaving
        // them installed after the window is gone would be a callback into freed
        // state.
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let localEscMonitor { NSEvent.removeMonitor(localEscMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Sizing

    private static let capsuleShape = NSSize(width: 440, height: 56)
    private static let cardShape = NSSize(width: 520, height: 150)
    /// Folded down: a 30 pt ink-red dot. Large enough to hit with a trackpad,
    /// small enough to stop covering a paragraph.
    private static let dotShape = NSSize(width: 30, height: 30)

    /// The header's height: the session name, the state pill and the two quiet
    /// controls. 30 pt is the pill's own height plus a hair of breathing room.
    private static let headerHeight: CGFloat = 30
    /// The card is never thinner than one comfortable line, and never taller than
    /// about eight of them: past that the transcript scrolls instead of pushing
    /// the stop button further down the screen.
    private static let bodyMinHeight: CGFloat = 46
    private static let bodyMaxHeight: CGFloat = 176
    /// Between the header and the card, and between the card and the sheet edge.
    private static let bodyGap: CGFloat = 6
    /// The card's distance from the sheet's left and right edges.
    private static let bodySideInset: CGFloat = 12
    private static let bodyTextInset = NSSize(width: 12, height: 10)
    /// The card's 1 pt border, counted twice.
    private static let bodyBorder: CGFloat = 2
    /// The transcript is read, not skimmed, so it is one point larger than the
    /// app's body role and gets extra leading.
    private static let bodySize: CGFloat = 14

    /// The width the text wraps at. The window keeps the capsule's width, so this
    /// is a constant: measuring the body never has to wait for a layout, and the
    /// height it asks for can never depend on the height it was given.
    private var bodyTextWidth: CGFloat {
        Self.capsuleShape.width
            - (Self.bodySideInset + Self.bodyTextInset.width) * 2
            - Self.bodyBorder
    }

    /// Whether the transcript card is part of the current shape.
    ///
    /// Not in `.edit` (that mode's body is the editable draft) and not when
    /// folded to the dot, and only once there is something to read: a dictation
    /// that has said nothing yet stays the compact capsule it always was.
    private var showsBody: Bool {
        !textView.string.isEmpty && mode != .edit && !(collapsed && mode == .recording)
    }

    /// Whether the header is on screen. It goes in and out with the card it
    /// belongs to, so it never floats over a bare capsule.
    private var showsHeader: Bool { showsBody }

    /// Whether the pill -- rather than the caption in the waveform's slot -- is
    /// the thing that states a pause. True exactly when the header is up: with a
    /// transcript on screen there is a place for the state that is not the
    /// control row, and one line stated once is the whole point of the merge.
    private var pillCarriesState: Bool { showsHeader }

    private func resize(to shape: NSSize) {
        let size = NSSize(width: shape.width + Self.margin * 2, height: shape.height + Self.margin * 2)
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        // Keep the top-left corner put: the window grows downward from the band
        // the user already has their hand near, so the stop button never moves.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        // A pill only while the shape is one row tall; the edit card and the
        // transcript card are rounded rectangles.
        card.cornerRadius = shape.height <= Self.capsuleShape.height ? shape.height / 2 : 20
    }

    private func applyMode(_ mode: Mode) {
        self.mode = mode
        let recording = mode == .recording
        let editing = mode == .edit
        let showingGlyph = recording || mode == .result
        // Folded is a recording-only shape: a dot cannot carry a status line, so
        // a finished result always expands back to the capsule.
        let folded = collapsed && recording
        // The card has to be measured before the frame is picked: the window's
        // height is whatever the words currently need.
        bodyHeight = resolveBodyHeight()
        resize(to: currentShape(folded: folded))
        // The left slot is the 朱紅 mic while recording, a check for a result.
        micView.isHidden = !showingGlyph
        micView.image = NSImage(systemSymbolName: recording ? "mic.fill" : "checkmark", accessibilityDescription: nil)
        micView.contentTintColor = recording ? Self.seal : Self.ink
        divider.isHidden = !recording
        waveView.isHidden = !recording
        countLabel.isHidden = !recording
        stopButton.isHidden = !recording || folded
        pauseButton.isHidden = !recording || folded
        handleView.isHidden = editing || folded
        statusLabel.isHidden = !(mode == .display || mode == .result)
        textField.isHidden = !editing
        hintLabel.isHidden = !editing
        if folded {
            // Only the mic survives: a red dot on the paper is the whole state.
            micView.isHidden = false
            divider.isHidden = true
            waveView.isHidden = true
            countLabel.isHidden = true
            hintLabel.isHidden = true
            textField.isHidden = true
        }
        layoutContents()
    }

    /// The shape the window wants right now.
    private func currentShape(folded: Bool) -> NSSize {
        if folded { return Self.dotShape }
        if mode == .edit { return Self.cardShape }
        guard showsBody else { return Self.capsuleShape }
        return NSSize(
            width: Self.capsuleShape.width,
            height: Self.capsuleShape.height + Self.headerHeight + Self.bodyGap
                + bodyHeight + Self.bodyGap
        )
    }

    /// How tall the transcript card wants to be: enough for every line it holds,
    /// clamped to a floor that fits one line and a ceiling that leaves the
    /// controls somewhere the user can still reach them.
    private func resolveBodyHeight() -> CGFloat {
        guard showsBody else { return 0 }
        // Pinned rather than tracked (see the text view's setup), so the wrap
        // point is known before the window height is chosen and the two can never
        // chase each other.
        textView.textContainer?.containerSize = NSSize(width: bodyTextWidth, height: .greatestFiniteMagnitude)
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return Self.bodyMinHeight
        }
        layout.ensureLayout(for: container)
        let wanted = ceil(layout.usedRect(for: container).height) + Self.bodyTextInset.height * 2
        return min(max(wanted + Self.bodyBorder, Self.bodyMinHeight), Self.bodyMaxHeight)
    }

    private func layoutContents() {
        let m = Self.margin
        let bounds = panel.contentView!.bounds
        // Everything in the control row is placed against the TOP of the sheet,
        // not its middle: the middle moves every time the transcript grows.
        let shapeTop = bounds.maxY - m
        let bandMidY = shapeTop - Self.capsuleShape.height / 2

        if collapsed, mode == .recording {
            micView.frame = NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
            layoutBody(bounds: bounds)
            return
        }

        let shapeH = bounds.height - m * 2
        let shapeW = bounds.width - m * 2

        micView.frame = NSRect(x: m + 22, y: bandMidY - 10, width: 20, height: 20)
        divider.frame = NSRect(x: m + 58, y: bandMidY - 12, width: 1, height: 24)
        waveView.frame = NSRect(x: m + 74, y: bandMidY - 15, width: 170, height: 30)
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: m + 286 - countLabel.frame.width, y: bandMidY - countLabel.frame.height / 2)
        // 26 pt, unfilled, 12 pt clear of the stop button: close enough to read as
        // one cluster, far enough that a mis-click does not end the recording.
        pauseButton.frame = NSRect(x: m + 304, y: bandMidY - 13, width: 26, height: 26)
        stopButton.frame = NSRect(x: m + 344, y: bandMidY - 17, width: 34, height: 34)
        handleView.frame = NSRect(x: m + 404, y: bandMidY - 11, width: 14, height: 22)

        statusLabel.sizeToFit()
        if mode == .recording, noticeWork != nil || (isPaused && !pillCarriesState) {
            // In the waveform's slot: after the hairline divider, and stopping
            // short of the right-aligned character count (which needs ~30 pt) so
            // a notice never runs under it.
            statusLabel.frame = NSRect(x: m + 78, y: bandMidY - statusLabel.frame.height / 2,
                                       width: 190, height: min(statusLabel.frame.height, Self.capsuleShape.height))
        } else {
            // Leave room for the ⋮⋮ grip on the right, and for the check on the left
            // when a result is showing.
            let leftPad: CGFloat = (mode == .result) ? 56 : 24
            let rightPad: CGFloat = 74
            statusLabel.frame = NSRect(x: m + leftPad, y: bandMidY - statusLabel.frame.height / 2,
                                       width: shapeW - leftPad - rightPad, height: min(statusLabel.frame.height, Self.capsuleShape.height))
        }

        if mode == .edit {
            hintLabel.sizeToFit()
            textField.frame = NSRect(x: m + 18, y: m + 34, width: shapeW - 36, height: shapeH - 62)
            hintLabel.frame.origin = NSPoint(x: m + 18, y: m + 16)
        }

        layoutBody(bounds: bounds)
    }

    /// Places the header and the transcript card, or takes them off screen when
    /// the shape does not have them.
    private func layoutBody(bounds: NSRect) {
        let m = Self.margin
        let hidden = !showsHeader
        titleLabel.isHidden = hidden
        statusPill.isHidden = hidden || mode != .recording
        copyButton.isHidden = hidden
        escapeHint.isHidden = hidden
        bodyCard.isHidden = !showsBody
        scrollView.isHidden = !showsBody
        guard showsHeader else { return }

        let shapeTop = bounds.maxY - m
        let headerTop = shapeTop - Self.capsuleShape.height
        let headerBottom = headerTop - Self.headerHeight
        let headerMidY = headerBottom + Self.headerHeight / 2

        // Right to left: the hint, then 複製, then the pill, so a long session
        // name gives way instead of pushing the controls off the edge.
        escapeHint.sizeToFit()
        escapeHint.frame.origin = NSPoint(x: bounds.width - m - 14 - escapeHint.frame.width,
                                          y: headerMidY - escapeHint.frame.height / 2)
        // Wide enough for 已複製, which the button swaps to after a copy, so its
        // frame never changes under the user's cursor.
        let copySize = copyButton.intrinsicContentSize
        let copyWidth = max(copySize.width, 64)
        let copyHeight = max(copySize.height, 22)
        copyButton.frame = NSRect(x: escapeHint.frame.minX - 12 - copyWidth,
                                  y: headerMidY - copyHeight / 2,
                                  width: copyWidth, height: copyHeight)
        // The pill's own constraints size its label to whatever is left inside
        // it, so the frame has to be the comfortable width or the state clips.
        let pillWidth = max(statusPill.fittingSize.width + 2, 56)
        let pillX = copyButton.frame.minX - 12 - pillWidth
        statusPill.frame = NSRect(x: pillX, y: headerMidY - 11, width: pillWidth, height: 22)

        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: m + 14, y: headerMidY - titleHeight / 2,
                                  width: max(0, pillX - 12 - (m + 14)), height: titleHeight)

        let cardTop = headerBottom - Self.bodyGap
        let cardBottom = m + Self.bodyGap
        bodyCard.frame = NSRect(x: m + Self.bodySideInset, y: cardBottom,
                                width: bounds.width - m * 2 - Self.bodySideInset * 2,
                                height: max(0, cardTop - cardBottom))
        scrollView.frame = NSRect(x: 1, y: 1,
                                  width: max(0, bodyCard.bounds.width - Self.bodyBorder),
                                  height: max(0, bodyCard.bounds.height - Self.bodyBorder))
        // The document is never shorter than the clip, so the text always starts
        // at the top of the card; past the card's height it simply scrolls.
        var contentHeight: CGFloat = 0
        if let layout = textView.layoutManager, let container = textView.textContainer {
            contentHeight = ceil(layout.usedRect(for: container).height) + Self.bodyTextInset.height * 2
        }
        textView.frame = NSRect(x: 0, y: 0,
                                width: scrollView.bounds.width,
                                height: max(scrollView.bounds.height, contentHeight))
    }

    // MARK: Showing

    func show(text: String, mode: Mode = .display, onSubmit: (() -> Void)? = nil, autoHide: TimeInterval? = nil) {
        // Once the user has dismissed the window, status updates stop reopening
        // it. `startRecording` clears the flag, so this only lasts one session.
        guard !dismissedByUser else { return }
        self.onSubmit = onSubmit
        hideWork?.cancel()
        hideWork = nil
        noticeWork?.cancel()
        noticeWork = nil

        applyMode(mode)
        switch mode {
        case .recording:
            waveView.reset()
            countLabel.stringValue = ""
        case .display, .result:
            statusLabel.stringValue = text
            statusLabel.isHidden = false
            statusLabel.sizeToFit()
            micView.isHidden = (mode == .display)
        case .edit:
            textField.stringValue = text
        }
        placeAndShow()

        if mode == .edit {
            // Make the panel key so the field takes keystrokes, then restore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self = self else { return }
                self.panel.makeKey()
                self.panel.makeFirstResponder(self.textField)
                self.textField.currentEditor()?.selectAll(nil)
            }
        }
        if let autoHide = autoHide {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // The words on screen are the reason this window exists, and a
                // status flash fading must not take them with it: with a
                // transcript up the window stays until Escape or the next
                // session, which is what the old 逐字稿 panel did.
                guard !self.showsBody else { return }
                self.hide()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// A status line that clears itself. Every terminal message uses this, so the
    /// window never lingers on screen after the job is done -- unless it is
    /// holding a transcript, which is worth reading even after the job is done.
    func flash(_ text: String, seconds: TimeInterval = 2.2) {
        show(text: text, mode: .display, autoHide: seconds)
    }

    /// A short warning shown INSIDE the recording window, in the waveform's slot:
    /// the 朱紅 mic, the character count, the stop button and the drag handle all
    /// stay where they are, and the waveform comes back when the warning expires.
    ///
    /// A recording must never be interrupted by a message. `flash` puts the
    /// window into its display mode, which hides the stop button -- the only way
    /// to end the recording from here -- so a meeting that warned about (say)
    /// system audio kept recording with no visible way to stop it.
    /// Outside a recording there is nothing to protect, so it falls back to `flash`.
    func notice(_ text: String, seconds: TimeInterval = 5) {
        guard mode == .recording else {
            flash(text, seconds: seconds)
            return
        }
        noticeWork?.cancel()
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        waveView.isHidden = true
        layoutContents()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .recording else { return }
            self.noticeWork = nil
            self.restoreWaveSlot()
            self.layoutContents()
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Puts the waveform's slot back the way a recording shows it. Shared by the
    /// two things that borrow the slot -- a `notice` and the pause state -- so
    /// there is one answer to "what goes back here", and one to where "paused" is
    /// stated.
    private func restoreWaveSlot() {
        statusLabel.isHidden = true
        waveView.isHidden = false
        guard isPaused else { return }
        // The meter is hidden rather than frozen: audio is being dropped, so a
        // live-looking waveform would be a lie. "Paused" is then said once,
        // wherever it can be said -- in the pill when the transcript has given the
        // header a home, in the caption when it has not.
        waveView.isHidden = true
        if pillCarriesState {
            statusPill.set(text: "已暫停", kind: .warn)
        } else {
            statusLabel.stringValue = "已暫停"
            statusLabel.isHidden = false
        }
    }

    /// The recording window: 朱紅 mic, live level, live character count, and the
    /// transcript card under them as soon as there are words for it.
    func startRecording() {
        // A new recording always gets its window back, however the last one was
        // dismissed, never starts out paused, and never shows the last session's
        // words as if they were being said now.
        dismissedByUser = false
        isPaused = false
        pauseButton.glyphKind = .pause
        clearTranscript()
        show(text: "", mode: .recording)
    }

    /// Pause / resume as the window shows it. The audio itself is dropped by the
    /// controller; this only tells the truth about it, so the stop button stays
    /// exactly where it was.
    func setPaused(_ paused: Bool) {
        guard mode == .recording else { return }
        isPaused = paused
        pauseButton.glyphKind = paused ? .play : .pause
        noticeWork?.cancel()
        noticeWork = nil
        if paused {
            restoreWaveSlot()
        } else {
            // Back to whatever the session was doing before the pause: the pill is
            // the only place that ever said anything else.
            statusPill.set(text: sessionStatus, kind: Self.pillKind(for: sessionStatus))
            restoreWaveSlot()
            waveView.reset()
        }
        layoutContents()
    }

    /// Folds the window down to a dot, or back.
    ///
    /// Persisted: someone who folded it to stop covering their notes wants it
    /// folded for the next meeting too, not re-taught every time.
    func toggleCollapsed() {
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: "hud.collapsed")
        applyMode(mode)
    }

    /// Shows the finished line with a check, then fades out on its own. Used
    /// after a paste so the text is visible for a moment and then gone.
    func showResult(_ text: String, seconds: TimeInterval = 2.2) {
        show(text: text, mode: .result, autoHide: seconds)
    }

    func setLevel(_ level: Float) {
        guard !waveView.isHidden else { return }
        waveView.push(CGFloat(level))
    }

    func setCount(_ characters: Int) {
        guard !countLabel.isHidden else { return }
        countLabel.stringValue = characters > 0 ? "\(characters) 字" : ""
        countLabel.sizeToFit()
        layoutContents()
    }

    private func placeAndShow() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "hud.originX") != nil
        var topLeft: NSPoint?
        if saved {
            let p = NSPoint(x: defaults.double(forKey: "hud.originX"), y: defaults.double(forKey: "hud.topY"))
            // Only reuse it if it still lands on a screen (monitors change).
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(p) }) { topLeft = p }
        }
        if topLeft == nil, let screen = NSScreen.main {
            // Default: top centre, just under the menu bar -- next to where the
            // screen-recording capsules live.
            let f = screen.visibleFrame
            let y = f.maxY - 8
            topLeft = NSPoint(x: f.midX - panel.frame.width / 2, y: y)
        }
        if let topLeft = topLeft {
            // The saved corner is the TOP-left, because that is the edge the
            // window grows away from: anchoring the bottom would walk the window
            // down the screen a little on every long dictation.
            panel.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - panel.frame.height))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        // Drop key/first-responder so a later synthesized Cmd+V can never land
        // in our own field, even if this panel was left key by a prior edit.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }

    /// Current text in the editable field (the user may have edited it).
    func getDisplayedText() -> String {
        textField.stringValue
    }

    /// Test hook: lets an offscreen harness render the real window to an image,
    /// since this machine cannot take screenshots of the live window.
    var viewForSnapshot: NSView { panel.contentView! }

    // MARK: - Session / transcript
    //
    // These are the calls the controller used to split between the capsule and
    // the separate transcript panel. They are one object's business now, which is
    // what makes it impossible for the two surfaces to disagree.

    /// Clears the card and shows the window. Called when a session starts, so the
    /// window the user closed last time is not withheld from them now.
    ///
    /// The shape a session starts in is decided here: a recording that is already
    /// running (the caller has just started one, and the controls are live) keeps
    /// the recording rows, and anything else becomes a status line -- a file
    /// import, or a left-over edit card that has to give way.
    func begin(title: String, status: String, show: Bool = true) {
        dismissedByUser = false
        clearTranscript()
        setTitle(title)
        if mode != .recording { mode = .display }
        // The card is empty again, so the window goes back to the compact capsule
        // until the first words arrive.
        applyMode(mode)
        setStatus(status)
        if show { panel.orderFrontRegardless() }
    }

    /// Names the session in the header: 聽寫, 會議逐字稿, or the file being
    /// imported. Also the panel's own title, which is what the window menu and
    /// Accessibility read a borderless window by.
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
        panel.title = title
    }

    /// The state of the transcript, not of the world: 辨識中… while it is
    /// listening, 已暫停, 沒有收到聲音, 完成, 失敗.
    ///
    /// Where it lands is decided here, once: the pill when the header is up (a
    /// recording with a transcript in it has no room for a status line in the
    /// control row), and the one-line status area otherwise. Never both -- saying
    /// the same thing twice is what the merge was for.
    func setStatus(_ status: String) {
        sessionStatus = status
        statusPill.set(text: status, kind: Self.pillKind(for: status))
        guard mode == .display || mode == .result else { return }
        statusLabel.stringValue = status
        statusLabel.isHidden = false
        statusLabel.sizeToFit()
        layoutContents()
    }

    /// Colour carries the state: green while it is working, quiet once it is
    /// done, red when the run failed. The caller only passes text.
    private static func pillKind(for status: String) -> StatusPill.Kind {
        if status.contains("失敗") || status.contains("錯誤") { return .error }
        if status.contains("已暫停") || status.contains("沒有收到聲音") { return .warn }
        if status.contains("完成") || status.contains("結束") { return .neutral }
        return .ok
    }

    /// Writes any segments newer than the last one shown.
    ///
    /// Segments arrive in order and their indices never repeat, so this is the one
    /// place that decides what is new. The card is then re-measured: appending is
    /// the only thing that grows the window.
    func append(_ segments: [TranscriptSegment], showSpeaker: Bool) {
        guard let storage = textView.textStorage else { return }
        let fresh = segments
            .filter { $0.index > lastTranscriptIndex }
            .sorted { $0.index < $1.index }
        if !fresh.isEmpty {
            transcriptRendered.append(contentsOf: fresh)
            transcriptSpeaker = showSpeaker
            let speakerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let bodyFont = NSFont.systemFont(ofSize: Self.bodySize)
            for segment in fresh {
                lastTranscriptIndex = max(lastTranscriptIndex, segment.index)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                // One line, two inks: the label is a quiet margin note, the speech
                // is the ink. Built as runs rather than one string so a long meeting
                // still reads as a dialogue and not as a log.
                let line = NSMutableAttributedString()
                if showSpeaker {
                    line.append(NSAttributedString(
                        string: "\(segment.speaker.label)：",
                        attributes: [
                            .font: speakerFont,
                            .foregroundColor: Self.inkSoft,
                            .paragraphStyle: paragraphStyle,
                        ]
                    ))
                }
                line.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: Self.ink,
                        .paragraphStyle: paragraphStyle,
                    ]
                ))
                storage.append(line)
            }
        }
        refreshCopyAvailability()
        applyMode(mode)
        if followsTail {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// A finished session keeps the card readable but stops claiming to be
    /// listening.
    func finish(status: String) {
        refreshCopyAvailability()
        setStatus(status)
    }

    /// The transcript is text the user may want elsewhere immediately; the button
    /// only makes sense once there is something to copy.
    private func refreshCopyAvailability() {
        copyButton.isEnabled = !textView.string.isEmpty
    }

    /// Empties the card. The window keeps its size until the next measurement,
    /// which is what collapses it back to the bare capsule.
    private func clearTranscript() {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        transcriptRendered = []
        transcriptSpeaker = false
        lastTranscriptIndex = 0
        followsTail = true
        refreshCopyAvailability()
    }

    /// Re-skins the body. It is rebuilt from `transcriptRendered` because the
    /// colours are baked into its attributed runs.
    private func redrawBody() {
        let all = transcriptRendered
        let speaker = transcriptSpeaker
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        transcriptRendered = []
        lastTranscriptIndex = 0
        append(all, showSpeaker: speaker)
    }

    /// Copies what the card is showing. The main window's history tab can do this
    /// too, but that means leaving the surface the user is watching.
    private func copyTranscript() {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let original = copyButton.title
        copyButton.title = "已複製"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.title = original
        }
    }

    @objc private func scrolled() {
        guard let documentView = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let bottom = documentView.frame.height - visible.height
        // A little slack, because the clip view rarely lands exactly on the end.
        followsTail = visible.origin.y >= bottom - 24
    }
}

// MARK: - The sheet

/// Draws the paper sheet and hosts the controls. Dragging anywhere except a
/// control (or the transcript) moves the window.
final class SheetView: NSView {
    var margin: CGFloat = 10
    /// Double-click folds / unfolds the window; a single click drags it.
    var onDoubleClick: (() -> Void)?
    var cornerRadius: CGFloat = 28
    var layoutHandler: (() -> Void)?
    /// Views that must keep their own mouse events -- selection, scrolling,
    /// typing -- instead of being treated as drag surface. The buttons are
    /// handled by type; these are the ones that have a reason to be clicked.
    var interactiveViews: [NSView] = []

    override func layout() {
        super.layout()
        layoutHandler?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = bounds.insetBy(dx: margin, dy: margin)
        let path = NSBezierPath(roundedRect: shape, xRadius: cornerRadius, yRadius: cornerRadius)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 60 / 255, green: 50 / 255, blue: 35 / 255, alpha: 0.22)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: DictationWindow.paperTop, ending: DictationWindow.paperBottom)?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        DictationWindow.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Everything is drag surface except the buttons, the editable field and the
    /// transcript card -- swallowing those would make the words unselectable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit else { return nil }
        if hit is CircleButton || hit is TextButton { return hit }
        for view in interactiveViews where hit === view || hit.isDescendant(of: view) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
        if let f = window?.frame {
            // The top-left is what is remembered: the window grows downward from
            // there, so a bottom-anchored origin would drift on every long
            // dictation.
            UserDefaults.standard.set(Double(f.minX), forKey: "hud.originX")
            UserDefaults.standard.set(Double(f.maxY), forKey: "hud.topY")
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - Live level meter

/// Scrolling bar meter driven by the microphone level.
final class WaveformView: NSView {
    private static let bars = 17
    private var levels: [CGFloat] = Array(repeating: 0, count: WaveformView.bars)

    func reset() {
        levels = Array(repeating: 0, count: Self.bars)
        needsDisplay = true
    }

    func push(_ value: CGFloat) {
        levels.removeFirst()
        levels.append(max(0, min(1, value)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar: CGFloat = 3, gap: CGFloat = 3
        let total = CGFloat(Self.bars) * bar + CGFloat(Self.bars - 1) * gap
        var x = (bounds.width - total) / 2
        DictationWindow.ink.setFill()
        for level in levels {
            // A little floor so silence still reads as a resting meter.
            let h = max(3, level * bounds.height)
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: bar, height: h)
            NSBezierPath(roundedRect: rect, xRadius: bar / 2, yRadius: bar / 2).fill()
            x += bar + gap
        }
    }
}

/// One round button, three glyphs: an ink circle with a paper square is stop,
/// bare ink bars are pause, a bare ink triangle is resume.
///
/// `filled` is false for pause so the window keeps exactly one filled ink
/// circle -- the one that ends the recording.
final class CircleButton: NSView {
    enum Glyph { case stop, pause, play }

    var fill: NSColor = .black { didSet { needsDisplay = true } }
    var glyph: NSColor = .white { didSet { needsDisplay = true } }
    var glyphKind: Glyph = .stop { didSet { needsDisplay = true } }
    /// Whether the circle itself is drawn. The glyph always is.
    var filled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let c = bounds
        if filled {
            fill.setFill()
            NSBezierPath(ovalIn: c).fill()
        }
        let ink = filled ? glyph : fill
        ink.setFill()

        switch glyphKind {
        case .stop:
            let s = c.width * 0.34
            let square = NSRect(x: c.midX - s / 2, y: c.midY - s / 2, width: s, height: s)
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
        case .pause:
            let w = c.width * 0.14
            let h = c.height * 0.36
            for dx in [-w, w] {
                let bar = NSRect(x: c.midX + dx - w / 2, y: c.midY - h / 2, width: w, height: h)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
        case .play:
            let h = c.height * 0.4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.midX - h * 0.28, y: c.midY - h / 2))
            path.line(to: NSPoint(x: c.midX - h * 0.28, y: c.midY + h / 2))
            path.line(to: NSPoint(x: c.midX + h * 0.5, y: c.midY))
            path.close()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The ⋮⋮ grip, showing the window can be moved.
final class HandleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DictationWindow.handleDot.setFill()
        for col in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX + (CGFloat(col) - 0.5) * 5.5
                let y = bounds.midY + (1 - CGFloat(row)) * 6.0
                NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
            }
        }
    }
}

// MARK: - Quiet text button

/// A word with a hover wash: the design kit's ghost button, drawn here instead.
///
/// Not `ThemedButton`, because this window is normally not the key window while a
/// recording runs and a stock `NSButton` spends the first click in a non-key
/// window waking the window instead of pressing itself. This is a plain view, so
/// it behaves exactly like the stop button beside it -- and it never takes key
/// status, so copying the transcript cannot swallow the user's next keystroke.
final class TextButton: NSView {
    var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    /// Hover is the only feedback: the one filled ink circle in this window is
    /// always "stop", so this button brings its own wash instead of a fill.
    private var hovering = false
    private var tracking: NSTrackingArea?

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(size.width) + 20, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            DictationWindow.surfaceAlt.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isEnabled
                ? (hovering ? DictationWindow.seal : DictationWindow.inkSoft)
                // Disabled is quiet ink, not a dimmer accent: "nothing to copy
                // yet" should read as a fact, not as a bug.
                : DictationWindow.inkSoft.withAlphaComponent(0.55),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (title as NSString).draw(at: point, withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `activeAlways`, not the design kit's `activeInKeyWindow`: this panel is
        // rarely key, which is the whole reason it exists.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - NSTextFieldDelegate

extension DictationWindow: NSTextFieldDelegate {
    /// Enter submits, Escape cancels. We do NOT submit on end-editing, so
    /// clicking away (or the panel resigning key) never causes a surprise paste.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissByUser()
            return true
        default:
            return false
        }
    }
}
