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

    // MARK: Palette

    /// The window's palette, read the same way as the capsule's: one static
    /// theme, because the attributed runs are built at append time and the
    /// theme only changes from `applyTheme` on the main thread.
    private(set) static var theme: Theme = ThemeCatalog.current

    private static var paper: NSColor { theme.background }
    private static var ink: NSColor { theme.textPrimary }
    private static var inkSoft: NSColor { theme.textSecondary }
    private static var seal: NSColor { theme.accent }
    private static var hairline: NSColor { theme.border.withAlphaComponent(0.75) }

    private var panel: Panel!
    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var hairlineView: NSView!
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

    override init() {
        super.init()

        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "逐字稿"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Self.paper
        panel.minSize = NSSize(width: 380, height: 200)
        panel.setFrameAutosaveName("OVCTranscriptWindow")
        panel.onEscape = { [weak self] in self?.dismissByUser() }
        panel.delegate = self

        buildHeader()
        buildBody()
        installEscapeMonitor()
    }

    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    // MARK: - Build

    private func buildHeader() {
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 44))
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "逐字稿")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Self.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = Self.inkSoft
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(statusLabel)

        hairlineView = NSView()
        hairlineView.wantsLayer = true
        hairlineView.layer?.backgroundColor = Self.hairline.cgColor
        hairlineView.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hairlineView)

        panel.contentView = header

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),

            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

            hairlineView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hairlineView.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            // 44pt from the top of the content: the header is the content view,
            // so anchoring to its bottom would put the rule at the window's foot.
            hairlineView.topAnchor.constraint(equalTo: header.topAnchor, constant: 44),
            hairlineView.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func buildBody() {
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = Self.ink
        textView.isRichText = true
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
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

        guard let content = panel.contentView else { return }
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 45),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
        statusLabel.stringValue = status
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        show()
    }

    func show() {
        guard !dismissedByUser else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    /// Writes any segments newer than the last one shown. Segments arrive in
    /// order and their indices never repeat, so this is the one place that
    /// decides what is new.
    func append(_ segments: [TranscriptSegment], showSpeaker: Bool) {
        guard !segments.isEmpty else { return }
        guard let storage = textView.textStorage else { return }

        var fresh = segments.filter { $0.index > lastIndex }
        guard !fresh.isEmpty else { return }
        fresh.sort { $0.index < $1.index }

        rendered.append(contentsOf: fresh)
        renderedSpeaker = showSpeaker

        for segment in fresh {
            lastIndex = max(lastIndex, segment.index)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if showSpeaker {
                let label = "\(segment.speaker.label)  "
                storage.append(NSAttributedString(
                    string: label,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: segment.speaker == .me ? Self.seal : Self.inkSoft,
                    ]
                ))
            }
            storage.append(NSAttributedString(
                string: text + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: Self.ink,
                ]
            ))
        }

        if followsTail {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// A finished session keeps the window readable but stops claiming to be
    /// listening.
    func finish(status: String) {
        statusLabel.stringValue = status
        panel.title = titleLabel.stringValue
    }

    /// Re-skins the window. The body is rebuilt from `rendered` because the
    /// colours are baked into its attributed runs.
    func applyTheme(_ theme: Theme) {
        TranscriptWindow.theme = theme
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        panel.backgroundColor = Self.paper
        titleLabel.textColor = Self.ink
        statusLabel.textColor = Self.inkSoft
        textView.textColor = Self.ink
        hairlineView.layer?.backgroundColor = Self.hairline.cgColor
        redrawBody()
    }

    private func redrawBody() {
        let all = rendered
        let speaker = renderedSpeaker
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        rendered = []
        lastIndex = 0
        append(all, showSpeaker: speaker)
    }

    /// Escape / the close button: hide the window, leave the recording alone.
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
    /// The window's own close button is also "hide", not "stop".
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissedByUser = true
        sender.orderOut(nil)
        return false
    }
}
