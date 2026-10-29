import AppKit

/// The pieces every screen is built from.
///
/// The window used to be plain AppKit controls on a tinted background: a beige
/// window with stock bezel buttons and a system tab strip inside it. That reads
/// as "the default app in a different colour", which is exactly what it was.
/// These primitives are the paper-and-ink vocabulary instead: cards with a hair
/// border, ink-filled primary actions, quiet text buttons, a pill for state, and
/// a tab strip that looks like a row of tabs rather than a control panel.
///
/// Everything takes a `Theme` and can be re-coloured in place, because the theme
/// picker changes the paper without rebuilding the window.

// MARK: - Contrast

extension Theme {
    /// Ink that sits on `accent` when the accent is used as a fill.
    ///
    /// Chosen by measured luminance rather than by "dark themes get white": the
    /// night accent is a light terracotta, and white on it is unreadable.
    var onAccent: NSColor {
        guard let rgb = accent.usingColorSpace(.sRGB) else { return .white }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return l > 0.42 ? NSColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: 1) : .white
    }
}

// MARK: - Text

/// Typography roles, so a screen never picks a size.
enum Ink {
    static func title(_ text: String, _ theme: Theme) -> NSTextField {
        label(text, theme, theme.fontTitle, theme.textPrimary)
    }
    static func heading(_ text: String, _ theme: Theme) -> NSTextField {
        label(text, theme, theme.fontHeading, theme.textPrimary)
    }
    static func body(_ text: String, _ theme: Theme) -> NSTextField {
        label(text, theme, theme.fontBody, theme.textPrimary)
    }
    static func small(_ text: String, _ theme: Theme) -> NSTextField {
        label(text, theme, theme.fontSmall, theme.textSecondary)
    }
    static func mono(_ text: String, _ theme: Theme) -> NSTextField {
        label(text, theme, theme.fontMono, theme.textSecondary)
    }

    /// Wrapping helper text. `secondary` unless a caller needs the danger ink.
    static func caption(_ text: String, _ theme: Theme, color: NSColor? = nil) -> NSTextField {
        // A plain 11 pt label is exactly as tall as its glyphs, so the first line
        // loses a pixel off the top wherever it is clipped by a scroll edge or a
        // layer. A minimum line height gives the cell its own margin instead of
        // asking every caller to pad the view around it.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = ceil(theme.fontSmall.pointSize * 1.5)
        paragraph.lineBreakMode = .byWordWrapping
        let field = NSTextField(wrappingLabelWithString: text)
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: theme.fontSmall,
                .foregroundColor: color ?? theme.textSecondary,
                .paragraphStyle: paragraph,
            ]
        )
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        return field
    }

    static func label(_ text: String, _ theme: Theme, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        return field
    }
}

/// A section heading: small, quiet, letter-spaced, with a hairline underneath.
final class SectionHeader: NSView {
    private let label: NSTextField
    private let line = NSView()

    init(_ text: String, theme: Theme) {
        label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: theme.textSecondary,
                .kern: 0.6,
            ]
        ))
        label.isSelectable = false
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        addSubview(label)
        addSubview(line)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Metrics.space2),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        line.layer?.backgroundColor = theme.border.cgColor
        label.textColor = theme.textSecondary
        if let cell = label.cell as? NSTextFieldCell {
            cell.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: theme.textSecondary,
                    .kern: 0.6,
                ]
            )
        }
    }
}

// MARK: - Surfaces

/// A sheet of paper: surface fill, hairline border, rounded corner.
final class ThemeCard: NSView {
    private var theme: Theme
    private(set) var fill: NSColor?

    init(theme: Theme, fill: NSColor? = nil, radius: CGFloat = Metrics.radiusMedium) {
        self.theme = theme
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = (fill ?? theme.surface).cgColor
        layer?.borderColor = theme.border.cgColor
    }

    /// For the permission banner, which is the same card in a warning wash.
    func setFill(_ color: NSColor?) {
        fill = color
        layer?.backgroundColor = (color ?? theme.surface).cgColor
    }
}

/// A container whose origin is the top-left, for scroll content.
///
/// `NSView` is bottom-up. A scroll view whose document view is not flipped lays
/// its content out from the bottom and clips the first line of a wrapping label
/// against the top edge, which is exactly how the 關鍵字 tab used to open.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A scroll view that opens at the top of its content and stays there.
///
/// A flipped document still opened scrolled to the bottom in the 關鍵字 tab,
/// because the document was a few points taller than the clip view and the clip
/// started at that offset -- which shaved the first line of the caption. Doing
/// the initial scroll once, after the first real layout, is the fix that does
/// not depend on when the content gets its height.
final class TopAnchoredScrollView: NSScrollView {
    private var didAnchor = false

    override func layout() {
        super.layout()
        guard !didAnchor, bounds.height > 1 else { return }
        didAnchor = true
        contentView.scroll(to: NSPoint(x: 0, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// One pixel of border colour.
final class Hairline: NSView {
    init(theme: Theme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        layer?.backgroundColor = theme.border.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: Theme) {
        layer?.backgroundColor = theme.border.cgColor
    }
}

// MARK: - Buttons

enum ButtonKind {
    case primary     // ink-filled, for the one action the screen is about
    case secondary   // bordered, on the surface
    case ghost       // text only, for the second row of quiet actions
    case danger      // outlined in danger ink
}

final class ThemedButton: NSButton {
    private(set) var kind: ButtonKind
    private var theme: Theme
    private var hovering = false
    private var selected = false
    private var tracking: NSTrackingArea?

    init(_ title: String, kind: ButtonKind = .secondary, theme: Theme) {
        self.kind = kind
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        self.title = title
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(size.width + 30, 54), height: 30)
    }

    /// A taller variant for the record actions, which carry the screen.
    func makeLarge() {
        heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    var titleText: String {
        get { title }
        set {
            title = newValue
            restyle()
            invalidateIntrinsicContentSize()
        }
    }

    /// Swaps the weight of an existing button (開始聽寫 becomes the loud one only
    /// when it is the action that makes sense right now).
    func setKind(_ kind: ButtonKind) {
        self.kind = kind
        restyle()
    }

    /// A tab that reads as the open one.
    func setSelected(_ on: Bool) {
        selected = on
        restyle()
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        restyle()
    }

    /// Disabled is a state, not a dimmer accent: an unfilled button with quiet
    /// ink reads as "not now", where 55% opacity on an accent fill reads as a bug.
    override var isEnabled: Bool {
        didSet { restyle() }
    }

    private var foreground: NSColor {
        if !isEnabled { return theme.textSecondary.withAlphaComponent(0.55) }
        switch kind {
        case .primary: return theme.onAccent
        case .secondary: return theme.textPrimary
        case .ghost: return selected ? theme.accent : theme.textSecondary
        case .danger: return theme.danger
        }
    }

    private var background: NSColor {
        if !isEnabled { return .clear }
        switch kind {
        case .primary:
            return hovering ? theme.accent.blended(withFraction: 0.12, of: .white) ?? theme.accent : theme.accent
        case .secondary:
            return hovering ? theme.surfaceAlt : theme.surface
        case .ghost:
            if selected { return theme.accentQuiet }
            return hovering ? theme.surfaceAlt : .clear
        case .danger:
            return hovering ? theme.danger.withAlphaComponent(0.10) : .clear
        }
    }

    private var stroke: NSColor {
        if !isEnabled { return theme.border.withAlphaComponent(0.7) }
        switch kind {
        case .primary: return .clear
        case .secondary: return theme.border
        case .ghost: return .clear
        case .danger: return theme.danger.withAlphaComponent(0.45)
        }
    }

    private func restyle() {
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = stroke.cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: kind == .primary || selected ? .semibold : .medium),
                .foregroundColor: foreground,
            ]
        )
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
}

// MARK: - State pill

/// The little dot-and-word badge in the header. Colour carries the state, so a
/// failure is visible from across the room without reading the sentence.
final class StatusPill: NSView {
    enum Kind { case neutral, ok, warn, error }

    private var theme: Theme
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var kind: Kind = .neutral

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.isSelectable = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5

        addSubview(dot)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(text: String, kind: Kind) {
        self.kind = kind
        label.stringValue = text
        applyTheme(theme)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let tint: NSColor
        switch kind {
        case .neutral: tint = theme.textSecondary
        case .ok: tint = theme.success
        case .warn: tint = theme.warning
        case .error: tint = theme.danger
        }
        dot.layer?.backgroundColor = tint.cgColor
        label.textColor = kind == .neutral ? theme.textSecondary : tint
        layer?.backgroundColor = theme.surfaceAlt.cgColor
        layer?.borderColor = theme.border.cgColor
    }
}

// MARK: - Tab strip

/// A row of tabs. Deliberately not `NSSegmentedControl`: the segmented control
/// is a control-bar idiom, and it forces every label into the same box.
final class TabStrip: NSView {
    private var buttons: [ThemedButton] = []
    private var theme: Theme
    private(set) var selectedIndex = 0
    var onSelect: ((Int) -> Void)?

    init(titles: [String], theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = Metrics.space2
        stack.alignment = .centerY
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (index, title) in titles.enumerated() {
            let button = ThemedButton(title, kind: .ghost, theme: theme)
            button.tag = index
            button.target = self
            button.action = #selector(didTap(_:))
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        setSelectedIndex(0, notify: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelectedIndex(_ index: Int, notify: Bool = true) {
        guard buttons.indices.contains(index) else { return }
        selectedIndex = index
        for (i, button) in buttons.enumerated() {
            button.setSelected(i == index)
        }
        if notify { onSelect?(index) }
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        buttons.forEach { $0.applyTheme(theme) }
    }

    @objc private func didTap(_ sender: NSButton) {
        setSelectedIndex(sender.tag)
    }
}

// MARK: - Small conveniences

extension NSStackView {
    /// A vertical stack with the app's spacing, so screens stop inventing it.
    static func column(_ views: [NSView],
                       spacing: CGFloat = Metrics.space3,
                       alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = Metrics.space2) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

extension NSView {
    /// Pins a child to all four edges with an inset.
    func embed(_ child: NSView, inset: CGFloat = Metrics.space4) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }
}
