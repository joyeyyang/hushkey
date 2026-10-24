import AppKit

/// Floating dictation capsule. Non-activating, so it never steals focus from the
/// field the text is going to land in.
///
/// Three shapes:
///   - recording: 朱紅 mic + live ink waveform + 字數 + stop button + drag handle
///   - display:   a one-line status or the finished text
///   - edit:      an editable card, Enter pastes, Escape cancels
///
/// Paper and ink only -- no accent colour except the mic. The capsule is
/// draggable from anywhere except the stop button, and the position is kept.
final class HUDWindow: NSObject {
    /// Borderless panels refuse key focus by default, which would make the
    /// editable field (and thus Enter-to-paste) dead. Force key capability.
    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    // MARK: Palette

    /// The palette the capsule draws with.
    ///
    /// Static because the small nested views (`CapsuleView`, `WaveformView`,
    /// `HandleView`, `CircleButton`) read it directly while drawing. Every one of
    /// them draws on the main thread, and this only changes from `applyTheme` on
    /// that same thread.
    private(set) static var theme: Theme = ThemeCatalog.current

    static var paperTop: NSColor { theme.surface }
    static var paperBottom: NSColor { theme.background }
    static var ink: NSColor { theme.textPrimary }
    static var inkSoft: NSColor { theme.textSecondary }
    static var seal: NSColor { theme.accent }
    static var hairline: NSColor { theme.border.withAlphaComponent(0.75) }
    static var handleDot: NSColor { theme.border }

    /// Margin left around the capsule inside the window so its shadow has room.
    private static let margin: CGFloat = 10

    enum Mode {
        case recording  // capsule: mic, level, count, stop
        case display    // one line of status
        case result     // one line of finished text, with a check
        case edit       // editable, Enter submits
    }

    private var mode: Mode = .display

    private var panel: HUDPanel!
    private var card: CapsuleView!

    private var micView: NSImageView!
    private var divider: NSView!
    private var waveView: WaveformView!
    private var countLabel: NSTextField!
    private var stopButton: CircleButton!
    private var pauseButton: CircleButton!
    private var handleView: HandleView!
    private var statusLabel: NSTextField!
    private var textField: NSTextField!
    private var hintLabel: NSTextField!

    private var hideWork: DispatchWorkItem?
    /// Pending revert of an in-recording `notice`. Non-nil while one is showing.
    private var noticeWork: DispatchWorkItem?
    private var onSubmit: (() -> Void)?

    /// Escape hides the capsule. While this is set, a later status update must
    /// not put it back in the user's face -- the point of pressing Escape is
    /// that the window stays gone, not that it blinks. Cleared when a new
    /// recording starts.
    private(set) var dismissedByUser = false
    private var escMonitor: Any?

    /// Called when the capsule's stop button is clicked.
    var onStop: (() -> Void)?

    /// Called when the pause / resume button is clicked during a recording.
    var onPause: (() -> Void)?

    /// Whether audio is currently being dropped. The capsule shows it in the
    /// waveform's slot, so the stop button never disappears mid-recording.
    private(set) var isPaused = false

    /// The capsule can be folded down to a dot during a recording, so it stops
    /// covering whatever the user is reading. Recording continues.
    private var collapsed = false

    override init() {
        self.panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the capsule draws its own, soft and warm
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true

        card = CapsuleView()
        card.autoresizingMask = [.width, .height]
        card.margin = Self.margin
        panel.contentView = card

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
        // ink circle in the capsule is always "end this".
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

        card.layoutHandler = { [weak self] in self?.layoutContents() }
        applyMode(.display)
        panel.orderOut(nil)
        installEscapeMonitor()
    }

    /// Re-skins the capsule in place.
    ///
    /// The views were built with fixed colours, so every one that carries a
    /// colour has to be told again; the panel's own appearance is set as well so
    /// the editable field's caret and selection follow the theme instead of
    /// staying dark-on-dark.
    func applyTheme(_ theme: Theme) {
        HUDWindow.theme = theme
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
        card.needsDisplay = true
        waveView.needsDisplay = true
        handleView.needsDisplay = true
    }

    /// Draws the capsule offscreen in its display shape, for a scripted visual
    /// check. Nothing is ordered front, so it never flashes on the user's screen.
    func snapshotPreview(text: String, to url: URL) {
        applyMode(.display)
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        layoutContents()
        render(to: url)
    }

    /// Offscreen render of the recording capsule in each of its states, so the
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

    private func render(to url: URL) {
        card.layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Escape closes the capsule and nothing else.
    ///
    /// The capsule is a non-activating panel, so it is never the key window and
    /// a local key monitor would never see the keystroke. A global monitor does,
    /// and that is allowed here because the app already requires Accessibility
    /// permission to paste. A global monitor cannot consume the event, so the
    /// Escape still reaches whatever app the user was typing in -- we only hide
    /// our own window.
    ///
    /// Deliberately NOT wired to `onStop`: Escape is "get this out of my sight",
    /// not "stop recording". Recording, the audio buffer, the recognition and the
    /// finished result are all untouched, and a pause is a separate control.
    private func installEscapeMonitor() {
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.panel.isVisible else { return }
            self.dismissCapsule()
        }
    }

    /// Hides the capsule until the next recording starts.
    func dismissCapsule() {
        dismissedByUser = true
        hide()
    }

    /// Re-arms the capsule for a session that is about to start, so an error or
    /// permission prompt in that session is allowed to appear even if the
    /// previous one was dismissed with Escape.
    func allowShowingAgain() {
        dismissedByUser = false
    }

    deinit {
        // The monitor outlives nothing: it holds no reference to us, but leaving
        // it installed after the window is gone would be a callback into freed
        // state.
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
    }

    // MARK: Sizing

    private static let capsuleShape = NSSize(width: 440, height: 56)
    private static let cardShape = NSSize(width: 520, height: 150)
    /// Folded down: a 30 pt ink-red dot. Large enough to hit with a trackpad,
    /// small enough to stop covering a paragraph.
    private static let dotShape = NSSize(width: 30, height: 30)

    private func resize(to shape: NSSize) {
        let size = NSSize(width: shape.width + Self.margin * 2, height: shape.height + Self.margin * 2)
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        // Keep the top-left corner put so a mode change does not make it jump.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        // The edit card is a rounded rectangle; every other shape is a pill.
        card.cornerRadius = shape.width == Self.cardShape.width ? 20 : shape.height / 2
    }

    private func applyMode(_ mode: Mode) {
        self.mode = mode
        let recording = mode == .recording
        let editing = mode == .edit
        let showingGlyph = recording || mode == .result
        // Folded is a recording-only shape: a dot cannot carry a status line, so
        // a finished result always expands back to the capsule.
        let folded = collapsed && recording
        resize(to: folded ? Self.dotShape : (editing ? Self.cardShape : Self.capsuleShape))
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

    private func layoutContents() {
        let m = Self.margin
        let midY = panel.contentView!.bounds.midY

        if collapsed, mode == .recording {
            let b = panel.contentView!.bounds
            micView.frame = NSRect(x: b.midX - 10, y: b.midY - 10, width: 20, height: 20)
            return
        }

        let shapeH = panel.contentView!.bounds.height - m * 2
        let shapeW = panel.contentView!.bounds.width - m * 2

        micView.frame = NSRect(x: m + 22, y: midY - 10, width: 20, height: 20)
        divider.frame = NSRect(x: m + 58, y: midY - 12, width: 1, height: 24)
        waveView.frame = NSRect(x: m + 74, y: midY - 15, width: 170, height: 30)
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: m + 286 - countLabel.frame.width, y: midY - countLabel.frame.height / 2)
        // 26 pt, unfilled, 12 pt clear of the stop button: close enough to read as
        // one cluster, far enough that a mis-click does not end the recording.
        pauseButton.frame = NSRect(x: m + 304, y: midY - 13, width: 26, height: 26)
        stopButton.frame = NSRect(x: m + 344, y: midY - 17, width: 34, height: 34)
        handleView.frame = NSRect(x: m + 404, y: midY - 11, width: 14, height: 22)

        statusLabel.sizeToFit()
        if mode == .recording, noticeWork != nil || isPaused {
            // In the waveform's slot: after the hairline divider, and stopping
            // short of the right-aligned character count (which needs ~30 pt) so
            // a notice never runs under it.
            statusLabel.frame = NSRect(x: m + 78, y: midY - statusLabel.frame.height / 2,
                                       width: 190, height: min(statusLabel.frame.height, shapeH))
        } else {
            // Leave room for the ⋮⋮ grip on the right, and for the check on the left
            // when a result is showing.
            let leftPad: CGFloat = (mode == .result) ? 56 : 24
            let rightPad: CGFloat = 74
            statusLabel.frame = NSRect(x: m + leftPad, y: midY - statusLabel.frame.height / 2,
                                       width: shapeW - leftPad - rightPad, height: min(statusLabel.frame.height, shapeH))
        }

        hintLabel.sizeToFit()
        textField.frame = NSRect(x: m + 18, y: m + 34, width: shapeW - 36, height: shapeH - 62)
        hintLabel.frame.origin = NSPoint(x: m + 18, y: m + 16)
    }

    // MARK: Showing

    func show(text: String, mode: Mode = .display, onSubmit: (() -> Void)? = nil, autoHide: TimeInterval? = nil) {
        // Once the user has dismissed the capsule, status updates stop reopening
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
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// A status line that clears itself. Every terminal message uses this, so the
    /// capsule never lingers on screen after the job is done.
    func flash(_ text: String, seconds: TimeInterval = 2.2) {
        show(text: text, mode: .display, autoHide: seconds)
    }

    /// A short warning shown INSIDE the recording capsule, in the waveform's slot:
    /// the 朱紅 mic, the character count, the stop button and the drag handle all
    /// stay where they are, and the waveform comes back when the warning expires.
    ///
    /// A recording must never be interrupted by a message. `flash` puts the
    /// capsule into its display mode, which hides the stop button -- the only way
    /// to end the recording from the capsule -- so a meeting that warned about
    /// (say) system audio kept recording with no visible way to stop it.
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
            guard let self = self, self.mode == .recording else { return }
            self.noticeWork = nil
            if self.isPaused {
                // The pause caption owns the waveform's slot until the user
                // resumes; a warning must not leave it looking live again.
                self.statusLabel.stringValue = "已暫停"
                self.statusLabel.isHidden = false
            } else {
                self.statusLabel.isHidden = true
                self.waveView.isHidden = false
            }
            self.layoutContents()
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The recording capsule: 朱紅 mic, live level, live character count.
    func startRecording() {
        // A new recording always gets its capsule back, however the last one was
        // dismissed, and never starts out paused.
        dismissedByUser = false
        isPaused = false
        pauseButton.glyphKind = .pause
        show(text: "", mode: .recording)
    }

    /// Pause / resume as the capsule shows it. The audio itself is dropped by the
    /// controller; this only tells the truth about it, in the waveform's slot, so
    /// the stop button stays exactly where it was.
    func setPaused(_ paused: Bool) {
        guard mode == .recording else { return }
        isPaused = paused
        pauseButton.glyphKind = paused ? .play : .pause
        noticeWork?.cancel()
        noticeWork = nil
        if paused {
            statusLabel.stringValue = "已暫停"
            statusLabel.isHidden = false
            waveView.isHidden = true
        } else {
            statusLabel.isHidden = true
            waveView.isHidden = false
            waveView.reset()
        }
        layoutContents()
    }

    /// Folds the capsule down to a dot, or back.
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
        var origin: NSPoint?
        if saved {
            let p = NSPoint(x: defaults.double(forKey: "hud.originX"), y: defaults.double(forKey: "hud.originY"))
            // Only reuse it if it still lands on a screen (monitors change).
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(p) }) { origin = p }
        }
        if origin == nil, let screen = NSScreen.main {
            // Default: top centre, just under the menu bar -- next to where the
            // screen-recording capsules live.
            let f = screen.visibleFrame
            origin = NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 8)
        }
        if let origin = origin { panel.setFrameOrigin(origin) }
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

    /// Test hook: lets an offscreen harness render the real capsule to an image,
    /// since this machine cannot take screenshots of the live window.
    var viewForSnapshot: NSView { panel.contentView! }
}

// MARK: - Capsule background

/// Draws the paper capsule and hosts the controls. Dragging anywhere except the
/// stop button moves the window.
final class CapsuleView: NSView {
    var margin: CGFloat = 10
    /// Double-click folds / unfolds the capsule; a single click drags it.
    var onDoubleClick: (() -> Void)?
    var cornerRadius: CGFloat = 28
    var layoutHandler: (() -> Void)?

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
        NSGradient(starting: HUDWindow.paperTop, ending: HUDWindow.paperBottom)?.draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        HUDWindow.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Everything is draggable except the stop button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit is CircleButton { return hit }
        return hit == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
        if let f = window?.frame {
            UserDefaults.standard.set(Double(f.origin.x), forKey: "hud.originX")
            UserDefaults.standard.set(Double(f.origin.y), forKey: "hud.originY")
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
        HUDWindow.ink.setFill()
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
/// `filled` is false for pause so the capsule keeps exactly one filled ink
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

/// The ⋮⋮ grip, showing the capsule can be moved.
final class HandleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        HUDWindow.handleDot.setFill()
        for col in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX + (CGFloat(col) - 0.5) * 5.5
                let y = bounds.midY + (1 - CGFloat(row)) * 6.0
                NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
            }
        }
    }
}

// MARK: - NSTextFieldDelegate

extension HUDWindow: NSTextFieldDelegate {
    /// Enter submits, Escape cancels. We do NOT submit on end-editing, so
    /// clicking away (or the panel resigning key) never causes a surprise paste.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissCapsule()
            return true
        default:
            return false
        }
    }
}
