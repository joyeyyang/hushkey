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

    // MARK: Palette (米白紙 + 朱紅)

    static let paperTop = NSColor(calibratedRed: 249 / 255, green: 246 / 255, blue: 239 / 255, alpha: 1)
    static let paperBottom = NSColor(calibratedRed: 240 / 255, green: 234 / 255, blue: 223 / 255, alpha: 1)
    static let ink = NSColor(calibratedRed: 40 / 255, green: 37 / 255, blue: 32 / 255, alpha: 1)
    static let inkSoft = NSColor(calibratedRed: 140 / 255, green: 132 / 255, blue: 116 / 255, alpha: 1)
    static let seal = NSColor(calibratedRed: 168 / 255, green: 62 / 255, blue: 42 / 255, alpha: 1)
    static let hairline = NSColor(calibratedRed: 60 / 255, green: 50 / 255, blue: 35 / 255, alpha: 0.16)
    static let handleDot = NSColor(calibratedRed: 196 / 255, green: 188 / 255, blue: 172 / 255, alpha: 1)

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
    private var handleView: HandleView!
    private var statusLabel: NSTextField!
    private var textField: NSTextField!
    private var hintLabel: NSTextField!

    private var hideWork: DispatchWorkItem?
    private var onSubmit: (() -> Void)?

    /// Called when the capsule's stop button is clicked.
    var onStop: (() -> Void)?

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
    }

    // MARK: Sizing

    private static let capsuleShape = NSSize(width: 440, height: 56)
    private static let cardShape = NSSize(width: 520, height: 150)

    private func resize(to shape: NSSize) {
        let size = NSSize(width: shape.width + Self.margin * 2, height: shape.height + Self.margin * 2)
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        // Keep the top-left corner put so a mode change does not make it jump.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        card.cornerRadius = shape.height == Self.capsuleShape.height ? shape.height / 2 : 20
    }

    private func applyMode(_ mode: Mode) {
        self.mode = mode
        let recording = mode == .recording
        let editing = mode == .edit
        let showingGlyph = recording || mode == .result
        resize(to: editing ? Self.cardShape : Self.capsuleShape)
        // The left slot is the 朱紅 mic while recording, a check for a result.
        micView.isHidden = !showingGlyph
        micView.image = NSImage(systemSymbolName: recording ? "mic.fill" : "checkmark", accessibilityDescription: nil)
        micView.contentTintColor = recording ? Self.seal : Self.ink
        divider.isHidden = !recording
        waveView.isHidden = !recording
        countLabel.isHidden = !recording
        stopButton.isHidden = !recording
        handleView.isHidden = editing
        statusLabel.isHidden = !(mode == .display || mode == .result)
        textField.isHidden = !editing
        hintLabel.isHidden = !editing
        layoutContents()
    }

    private func layoutContents() {
        let m = Self.margin
        let midY = panel.contentView!.bounds.midY

        let shapeH = panel.contentView!.bounds.height - m * 2
        let shapeW = panel.contentView!.bounds.width - m * 2

        micView.frame = NSRect(x: m + 22, y: midY - 10, width: 20, height: 20)
        divider.frame = NSRect(x: m + 58, y: midY - 12, width: 1, height: 24)
        waveView.frame = NSRect(x: m + 74, y: midY - 15, width: 170, height: 30)
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: m + 300 - countLabel.frame.width, y: midY - countLabel.frame.height / 2)
        stopButton.frame = NSRect(x: m + 344, y: midY - 17, width: 34, height: 34)
        handleView.frame = NSRect(x: m + 404, y: midY - 11, width: 14, height: 22)

        statusLabel.sizeToFit()
        // Leave room for the ⋮⋮ grip on the right, and for the check on the left
        // when a result is showing.
        let leftPad: CGFloat = (mode == .result) ? 56 : 24
        let rightPad: CGFloat = 74
        statusLabel.frame = NSRect(x: m + leftPad, y: midY - statusLabel.frame.height / 2,
                                   width: shapeW - leftPad - rightPad, height: min(statusLabel.frame.height, shapeH))

        hintLabel.sizeToFit()
        textField.frame = NSRect(x: m + 18, y: m + 34, width: shapeW - 36, height: shapeH - 62)
        hintLabel.frame.origin = NSPoint(x: m + 18, y: m + 16)
    }

    // MARK: Showing

    func show(text: String, mode: Mode = .display, onSubmit: (() -> Void)? = nil, autoHide: TimeInterval? = nil) {
        self.onSubmit = onSubmit
        hideWork?.cancel()
        hideWork = nil

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

    /// The recording capsule: 朱紅 mic, live level, live character count.
    func startRecording() {
        show(text: "", mode: .recording)
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

/// Ink circle with a paper square: stop and paste.
final class CircleButton: NSView {
    var fill: NSColor = .black
    var glyph: NSColor = .white
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let s = bounds.width * 0.34
        let square = NSRect(x: bounds.midX - s / 2, y: bounds.midY - s / 2, width: s, height: s)
        glyph.setFill()
        NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
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
            hide()
            return true
        default:
            return false
        }
    }
}
