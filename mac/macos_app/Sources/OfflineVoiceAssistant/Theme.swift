import AppKit

/// A complete palette + type scale for one look.
///
/// The five themes are not tints of one another: they are five different
/// presses. `paper` is the original capsule (米白紙 + 朱紅 seal); the others move
/// the same paper-and-ink logic into a blue-grey millboard, a moss-green stock
/// and a terracotta stock, plus one dark ink-on-night theme.
///
/// Every colour below is built in sRGB with `NSColor(srgbRed:green:blue:alpha:)`
/// so it does not shift with the display profile. Contrast was measured, not
/// eyeballed: see the ratio noted beside each family.
///
/// `@unchecked` because AppKit does not annotate `NSColor` or `NSFont` as
/// `Sendable`, though both are immutable once built and safe to read from any
/// thread. This keeps ten Swift 6 warnings (five colours, five fonts) out of the
/// build; a plain `Sendable` is otherwise exactly what we want.
struct Theme: Identifiable, @unchecked Sendable {
    let id: String            // "paper" | "night" | "slate" | "moss" | "clay"
    let name: String          // 中文 display name
    let isDark: Bool

    let background: NSColor   // window
    let surface: NSColor      // cards, sheets
    let surfaceAlt: NSColor   // hover, inset areas
    let textPrimary: NSColor
    let textSecondary: NSColor
    let accent: NSColor
    let accentQuiet: NSColor  // accent at low emphasis (selected row, badge)
    let border: NSColor
    let success: NSColor
    let warning: NSColor
    let danger: NSColor

    // Typography roles, not raw sizes scattered at call sites.
    let fontTitle: NSFont
    let fontHeading: NSFont
    let fontBody: NSFont
    let fontSmall: NSFont
    let fontMono: NSFont
}

// MARK: - sRGB construction

/// Builds a colour from a 0xRRGGBB literal in sRGB. Never use
/// `NSColor(calibratedRed:...)` here: calibrated colours are re-mapped per
/// display profile, so a "paper" that looks right on one screen drifts warm or
/// cold on the next.
private func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// 15% of `accent` laid over `surface` -- the wash behind a selected row or a
/// badge. Mixed in sRGB on purpose, the way a translucent ink would sit on the
/// sheet: it keeps the paper's warmth instead of turning grey.
private func wash(_ accent: UInt32, over surface: UInt32, amount: CGFloat = 0.15) -> NSColor {
    func part(_ h: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((h >> shift) & 0xFF) }
    return NSColor(
        srgbRed: (part(accent, 16) * amount + part(surface, 16) * (1 - amount)) / 255,
        green: (part(accent, 8) * amount + part(surface, 8) * (1 - amount)) / 255,
        blue: (part(accent, 0) * amount + part(surface, 0) * (1 - amount)) / 255,
        alpha: 1
    )
}

// MARK: - The five

enum ThemeCatalog {
    /// Every theme, in the order the picker shows them. `paper` first because it
    /// is the app's original look, `night` second because it is the only dark one.
    static let all: [Theme] = [paper, night, slate, moss, clay]

    /// 米白紙 + 朱紅. Body 15.45:1 on the window, 16.84:1 on a card; the seal
    /// red clears 5.59:1 as a 13 pt label, well past the 3:1 it needs.
    static let paper = Theme(
        id: "paper",
        name: "米白紙",
        isDark: false,
        background: srgb(0xF6F3EC),
        surface: srgb(0xFFFDF8),
        surfaceAlt: srgb(0xFAF6ED),
        textPrimary: srgb(0x1F1B16),
        textSecondary: srgb(0x6B6257),
        accent: srgb(0xA83E2A),
        accentQuiet: wash(0xA83E2A, over: 0xFFFDF8),
        border: srgb(0xE2DACA),
        success: srgb(0x3F6B4A),
        warning: srgb(0x8A5A18),
        danger: srgb(0x872733),
        fontTitle: TypeScale.title,
        fontHeading: TypeScale.heading,
        fontBody: TypeScale.body,
        fontSmall: TypeScale.small,
        fontMono: TypeScale.mono
    )

    /// Ink at night. The accent is lifted to a brighter terracotta so it still
    /// reads as a seal rather than going brown: 5.21:1 on the window, 4.78:1 on
    /// a card.
    static let night = Theme(
        id: "night",
        name: "夜墨",
        isDark: true,
        background: srgb(0x14120F),
        surface: srgb(0x1E1B17),
        surfaceAlt: srgb(0x272420),
        textPrimary: srgb(0xEDE7DC),
        textSecondary: srgb(0x9A9084),
        accent: srgb(0xD4674F),
        accentQuiet: wash(0xD4674F, over: 0x1E1B17),
        border: srgb(0x2E2A24),
        success: srgb(0x7FAE86),
        warning: srgb(0xC99A4E),
        danger: srgb(0xD8626C),
        fontTitle: TypeScale.title,
        fontHeading: TypeScale.heading,
        fontBody: TypeScale.body,
        fontSmall: TypeScale.small,
        fontMono: TypeScale.mono
    )

    /// Cold millboard and a blueprint-blue ink. No pure white card: `surface` is
    /// a hair below #FFFFFF so the sheet never glares against the grey desk.
    static let slate = Theme(
        id: "slate",
        name: "石板",
        isDark: false,
        background: srgb(0xF1F3F5),
        surface: srgb(0xFBFCFC),
        surfaceAlt: srgb(0xF5F7F8),
        textPrimary: srgb(0x1B2126),
        textSecondary: srgb(0x5D6B76),
        accent: srgb(0x2F5D6B),
        accentQuiet: wash(0x2F5D6B, over: 0xFBFCFC),
        border: srgb(0xDDE2E6),
        success: srgb(0x3A6B52),
        warning: srgb(0x8A5A18),
        danger: srgb(0x9B3A32),
        fontTitle: TypeScale.title,
        fontHeading: TypeScale.heading,
        fontBody: TypeScale.body,
        fontSmall: TypeScale.small,
        fontMono: TypeScale.mono
    )

    /// Damp-green stock, like a field notebook. `success` is pushed toward teal
    /// (#2C6552) so it cannot be mistaken for the sage-green accent.
    static let moss = Theme(
        id: "moss",
        name: "苔綠",
        isDark: false,
        background: srgb(0xF2F2ED),
        surface: srgb(0xFBFAF5),
        surfaceAlt: srgb(0xF5F4EC),
        textPrimary: srgb(0x1B211A),
        textSecondary: srgb(0x5F6A5C),
        accent: srgb(0x4A6B4E),
        accentQuiet: wash(0x4A6B4E, over: 0xFBFAF5),
        border: srgb(0xDFE0D5),
        success: srgb(0x2C6552),
        warning: srgb(0x85571A),
        danger: srgb(0x9C3A2E),
        fontTitle: TypeScale.title,
        fontHeading: TypeScale.heading,
        fontBody: TypeScale.body,
        fontSmall: TypeScale.small,
        fontMono: TypeScale.mono
    )

    /// Terracotta on unbleached paper. The accent sits at 4.16:1 on the window --
    /// past the 3:1 a label needs, short of 4.5:1, so the clay accent is for
    /// labels and button fills, not for body-size accent text.
    static let clay = Theme(
        id: "clay",
        name: "陶土",
        isDark: false,
        background: srgb(0xF7F1EC),
        surface: srgb(0xFFFBF7),
        surfaceAlt: srgb(0xFBF4EE),
        textPrimary: srgb(0x241C17),
        textSecondary: srgb(0x6E5F55),
        accent: srgb(0xB45B3E),
        accentQuiet: wash(0xB45B3E, over: 0xFFFBF7),
        border: srgb(0xE7DAD0),
        success: srgb(0x456B4C),
        warning: srgb(0x8A5A18),
        danger: srgb(0x872A33),
        fontTitle: TypeScale.title,
        fontHeading: TypeScale.heading,
        fontBody: TypeScale.body,
        fontSmall: TypeScale.small,
        fontMono: TypeScale.mono
    )

    /// Falls back to `paper` for anything unknown, and accepts the legacy
    /// "light"/"dark" codes the settings popup used before themes existed.
    static func theme(id: String) -> Theme {
        switch id {
        case "night", "dark": return night
        case "slate": return slate
        case "moss": return moss
        case "clay": return clay
        default: return paper
        }
    }

    /// Reads `settings.theme`. "system" (and an unset key) resolves through the
    /// effective appearance, so the app follows the OS until the user picks.
    static var current: Theme {
        let id = UserDefaults.standard.string(forKey: "settings.theme") ?? "system"
        guard id == "system" else { return theme(id: id) }
        return systemIsDark ? night : paper
    }

    static func setCurrent(id: String) {
        UserDefaults.standard.set(id, forKey: "settings.theme")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Posted after `setCurrent` so open windows can re-apply without a relaunch.
    static let didChange = Notification.Name("ThemeCatalog.didChange")

    /// NSApp is implicitly unwrapped, so a headless caller (a render harness)
    /// must not touch it blindly.
    private static var systemIsDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Typography

/// One type scale for every palette: a theme changes the paper, not the
/// typeface. A call site asks for a *role* so sizes never get re-invented.
private enum TypeScale {
    static let title = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let heading = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 13)
    static let small = NSFont.systemFont(ofSize: 11)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

// MARK: - Metrics

/// Shared spacing and radius scale, so screens stop inventing numbers.
enum Metrics {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 14
}
