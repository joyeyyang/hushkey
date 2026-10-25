import AppKit

/// The live transcript: what the user actually said, word for word.
///
/// This window exists to answer one question while a recording is running --
/// "did it hear me?" -- so it renders the raw segment text and nothing else: no
/// polishing, no summarising, no punctuation repair. The polished text is a
/// different surface (the capsule / the pasted result); mixing the two here
/// would make it impossible to see a recognition mistake.
///
/// Escape closes THIS window and nothing else. Recording, recognition, the audio
/// buffer and the finished result all keep going, which is the difference
/// between "hide the window" and "stop": stopping is the capsule's stop button,
/// and pausing is its own control.
///
/// Visually it is the capsule's sibling: a borderless sheet of paper with the
/// same corner radius, hairline and soft shadow, a state pill in the header and
/// the transcript on a card. The rounded shape and its shadow have to live in
/// the content view, because a borderless window has no frame to draw.
final class TranscriptWindow: NSObject {
    /// Borderless panels refuse key focus, which would leave Escape (and text
    /// selection) dead.
    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        /// Escape travels up the responder chain to the window when the read-only
        /// text view does not consume it.
        override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }
    }

    /// The sheet the panel is made of: paper fill, hairline border, 14 pt radius.
    ///
    /// `masksToBounds` clips the contents to that radius *and* gives the window
    /// server the rounded alpha shape it builds the soft shadow from, so the
    /// shadow follows the corners instead of the window rectangle.
    private final class SurfaceView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = Metrics.radiusLarge
            layer?.borderWidth = 1
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    // MARK: Palette

    /// The window's palette, read the same way as the capsule's: one static
    /// theme, because the attributed runs are built at append time and the
    /// theme only changes from `applyTheme` on the main thread.
    private(set) static var theme: Theme = ThemeCatalog.current

    private static var ink: NSColor { theme.textPrimary }
    private static var inkSoft: NSColor { theme.textSecondary }

    private static let frameAutosaveName = "OVCTranscriptWindow"
    /// The transcript is read, not skimmed, so it is one point larger than the
    /// app's body role and gets extra leading.
    private static let bodySize: CGFloat = 14

    private var panel: Panel!
    private var surface: SurfaceView!
    private var titleLabel: NSTextField!
    /// Copies the transcript that is on screen. The main window's history tab
    /// can do this too, but that means leaving the surface the user is
    /// watching, and the point of this button is to skip that trip.
    private let copyButton = ThemedButton("複製", kind: .ghost, theme: ThemeCatalog.current)
    private var statusPill: StatusPill!
    private var escapeHint: NSTextField!
    private var card: ThemeCard!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var escapeMonitor: Any?

    /// Everything written so far, kept so a theme change can re-colour the body:
    /// the colours live in the attributed runs, not in the text view.
    private var rendered: [TranscriptSegment] = []
    private var renderedSpeaker = false

    /// Set when the user closes the window themselves, so a later status update
    /// does not pop it back up in their face. Cleared when a session starts.
    private(set) var dismissedByUser = false
    /// The last segment index written, so a repeated poll cannot double-print.
    private var lastIndex = 0
    /// Whether the last append is allowed to scroll. False while the user has
    /// scrolled up to read something, true again when they return to the bottom.
    private var followsTail = true

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
        super.init()

        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "逐字稿"
        panel.isReleasedWhenClosed = false
        // The sheet draws its own paper and the window server draws the shadow;
        // an opaque backing would paint a square behind the rounded corners.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 380, height: 200)
        panel.onEscape = { [weak self] in self?.dismissByUser() }
        panel.delegate = self

        // Restore the position the user left it in. A fresh install has no saved
        // frame, and a borderless panel at (0, 0) would open in the corner.
        let restored = panel.setFrameUsingName(Self.frameAutosaveName)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { panel.center() }

        buildSurface()
        buildHeader()
        buildBody()
        applyTheme(Self.theme)
        installEscapeMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeCatalog.didChange,
            object: nil
        )
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Build

    private func buildSurface() {
        surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
    }

    private func buildHeader() {
        titleLabel = NSTextField(labelWithString: "逐字稿")
        titleLabel.font = NSFont.systemFont(ofSize: Self.theme.fontBody.pointSize, weight: .semibold)
        titleLabel.textColor = Self.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        // The pill states the fact; the title is what gives way when it is long.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(titleLabel)

        statusPill = StatusPill(theme: Self.theme)
        statusPill.set(text: "", kind: .neutral)
        surface.addSubview(statusPill)

        escapeHint = Ink.small("Esc 關閉", Self.theme)
        escapeHint.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(escapeHint)

        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        copyButton.toolTip = "把目前看到的逐字稿放進剪貼簿"
        copyButton.isEnabled = false
        surface.addSubview(copyButton)

        NSLayoutConstraint.activate([
            statusPill.topAnchor.constraint(equalTo: surface.topAnchor, constant: 13),
            copyButton.trailingAnchor.constraint(equalTo: escapeHint.leadingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            escapeHint.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            escapeHint.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            statusPill.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusPill.leadingAnchor, constant: -12),
        ])
    }

    private func buildBody() {
        card = ThemeCard(theme: Self.theme)
        // Keeps the scroller and the text off the card's rounded corners.
        card.layer?.masksToBounds = true
        surface.addSubview(card)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.systemFont(ofSize: Self.bodySize)
        textView.textColor = Self.ink
        textView.isRichText = true
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // A meeting transcript grows past a screenful; laying out only what is
        // visible keeps the tail-following scroll smooth while text streams in.
        textView.layoutManager?.allowsNonContiguousLayout = true

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        card.embed(scrollView, inset: 1)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
        ])
    }

    private func installEscapeMonitor() {
        // The panel's cancelOperation covers Escape once it is key. This also
        // covers the case where the text view swallows the key first.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel.isVisible, self.panel.isKeyWindow else {
                return event
            }
            self.dismissByUser()
            return nil
        }
    }

    // MARK: - Session

    /// Clears the window and shows it. Called when a recording starts, so the
    /// window the user closed last time is not withheld from them now.
    func begin(title: String, status: String = "辨識中…") {
        dismissedByUser = false
        lastIndex = 0
        followsTail = true
        rendered = []
        renderedSpeaker = false
        titleLabel.stringValue = title
        setStatus(status)
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        copyButton.isEnabled = false
        show()
    }

    func show() {
        guard !dismissedByUser else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Renders the paper offscreen, for the visual self-test.
    ///
    /// The panel is borderless and transparent with the sheet drawn by its
    /// content view, so capturing that view is what the user actually sees --
    /// minus the window server's shadow, which cannot be captured this way.
    func snapshot(to url: URL) -> Bool {
        guard let view = panel.contentView, view.bounds.width > 1 else { return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Hide without recording a dismissal: the window may come back for a later
    /// status update, which is the difference from `dismissByUser`.
    func hide() {
        panel.orderOut(nil)
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setStatus(_ status: String) {
        statusPill.set(text: status, kind: Self.pillKind(for: status))
    }

    /// Colour carries the state: green while it is working, quiet once it is
    /// done, red when the run failed. The caller only passes text.
    private static func pillKind(for status: String) -> StatusPill.Kind {
        if status.contains("失敗") || status.contains("錯誤") { return .error }
        if status.contains("已暫停") || status.contains("沒有收到聲音") { return .warn }
        if status.contains("完成") || status.contains("結束") { return .neutral }
        return .ok
    }

    /// Writes any segments newer than the last one shown. Segments arrive in
    /// order and their indices never repeat, so this is the one place that
    /// decides what is new.
    @objc private func copyTranscript() {
        let text = textView.string
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let original = copyButton.titleText
        copyButton.titleText = "已複製"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.titleText = original
        }
    }

    func append(_ segments: [TranscriptSegment], showSpeaker: Bool) {
        defer { refreshCopyAvailability() }
        guard !segments.isEmpty else { return }
        guard let storage = textView.textStorage else { return }

        var fresh = segments.filter { $0.index > lastIndex }
        guard !fresh.isEmpty else { return }
        fresh.sort { $0.index < $1.index }

        rendered.append(contentsOf: fresh)
        renderedSpeaker = showSpeaker

        let speakerFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: Self.bodySize)

        for segment in fresh {
            lastIndex = max(lastIndex, segment.index)
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

        if followsTail {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// The transcript is text the user may want elsewhere immediately; the
    /// button only makes sense once there is something to copy.
    private func refreshCopyAvailability() {
        copyButton.isEnabled = !textView.string.isEmpty
    }

    /// A finished session keeps the window readable but stops claiming to be
    /// listening.
    func finish(status: String) {
        refreshCopyAvailability()
        setStatus(status)
        panel.title = titleLabel.stringValue
    }

    /// Re-skins the window. The body is rebuilt from `rendered` because the
    /// colours are baked into its attributed runs.
    func applyTheme(_ theme: Theme) {
        TranscriptWindow.theme = theme
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        surface.layer?.backgroundColor = theme.background.cgColor
        surface.layer?.borderColor = theme.border.cgColor
        titleLabel.font = NSFont.systemFont(ofSize: theme.fontBody.pointSize, weight: .semibold)
        titleLabel.textColor = theme.textPrimary
        escapeHint.textColor = theme.textSecondary
        statusPill.applyTheme(theme)
        copyButton.applyTheme(theme)
        card.applyTheme(theme)
        textView.textColor = theme.textPrimary
        redrawBody()
    }

    /// One notification carries no payload: the palette is read from the
    /// catalog, which is why a window open during the switch recolours in place.
    @objc private func themeDidChange(_ note: Notification) {
        applyTheme(ThemeCatalog.current)
    }

    private func redrawBody() {
        let all = rendered
        let speaker = renderedSpeaker
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        rendered = []
        lastIndex = 0
        append(all, showSpeaker: speaker)
    }

    /// Escape — there is no titlebar close button on a borderless panel: hide
    /// the window, leave the recording alone.
    func dismissByUser() {
        dismissedByUser = true
        panel.orderOut(nil)
    }

    /// Closing the panel while a session is live must not end it either.
    func closeForSessionEnd() {
        panel.orderOut(nil)
    }

    @objc private func scrolled() {
        guard let documentView = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let bottom = documentView.frame.height - visible.height
        // A little slack, because the clip view rarely lands exactly on the end.
        followsTail = visible.origin.y >= bottom - 24
    }
}

// MARK: - NSWindowDelegate

extension TranscriptWindow: NSWindowDelegate {
    /// The window's own close path is also "hide", not "stop".
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissedByUser = true
        sender.orderOut(nil)
        return false
    }
}
