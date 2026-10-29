import SwiftUI
import UIKit

/// The app's papers, in one place.
///
/// Flat on purpose: no capsules, no glass, no gradients. The Mac's window is paper
/// with ink on it, and the phone screens are the same ink on the same papers, so
/// the two read as one product. Every view pulls from here rather than repeating
/// the numbers, which is what stopped the recorder and the model screen from
/// drifting into two slightly different greys.
///
/// The five themes and their colours are the Mac's, hex for hex
/// (`mac/macos_app/Sources/OfflineVoiceAssistant/Theme.swift`). "The same on both
/// platforms" was the point of the alignment work, and a phone that offered four
/// slightly different papers would be the same failure with more steps.
struct PaperTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool

    /// Body text.
    let ink: Color
    /// Captions, secondary lines, anything that must recede.
    let dim: Color
    /// The window behind everything.
    let paper: Color
    /// Cards and inset areas: `paper` with a little of the ink's opposite mixed
    /// in, so one wash works over light and dark paper alike.
    let wash: Color
    /// The seal: accents, toggles, the recording ring.
    let seal: Color
}

/// Builds a colour from a 0xRRGGBB literal in sRGB.
///
/// Explicitly sRGB, never the display profile: a "paper" that looks right on one
/// screen must not drift warm or cold on the next, and the Mac builds its themes
/// the same way.
private func srgb(_ hex: UInt32) -> Color {
    Color(
        .sRGB,
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        opacity: 1
    )
}

enum PaperThemes {
    /// Every theme, in the order the picker shows them: the Mac's order, so the
    /// same row is in the same place on both devices.
    static let all: [PaperTheme] = [paper, night, slate, moss, clay]

    /// 米白紙 + 朱紅, the Mac's default.
    static let paper = PaperTheme(
        id: "paper", name: "米白紙", isDark: false,
        ink: srgb(0x1F1B16), dim: srgb(0x6B6257),
        paper: srgb(0xF6F3EC), wash: srgb(0xFFFDF8), seal: srgb(0xA83E2A)
    )

    /// Ink at night. The accent is lifted to a brighter terracotta so it still
    /// reads as a seal rather than going brown.
    static let night = PaperTheme(
        id: "night", name: "夜墨", isDark: true,
        ink: srgb(0xEDE7DC), dim: srgb(0x9A9084),
        paper: srgb(0x14120F), wash: srgb(0x1E1B17), seal: srgb(0xD4674F)
    )

    /// Cold millboard and a blueprint-blue ink.
    static let slate = PaperTheme(
        id: "slate", name: "石板", isDark: false,
        ink: srgb(0x1B2126), dim: srgb(0x5D6B76),
        paper: srgb(0xF1F3F5), wash: srgb(0xFBFCFC), seal: srgb(0x2F5D6B)
    )

    /// Damp-green stock, like a field notebook.
    static let moss = PaperTheme(
        id: "moss", name: "苔綠", isDark: false,
        ink: srgb(0x1B211A), dim: srgb(0x5F6A5C),
        paper: srgb(0xF2F2ED), wash: srgb(0xFBFAF5), seal: srgb(0x4A6B4E)
    )

    /// Terracotta on unbleached paper.
    static let clay = PaperTheme(
        id: "clay", name: "陶土", isDark: false,
        ink: srgb(0x241C17), dim: srgb(0x6E5F55),
        paper: srgb(0xF7F1EC), wash: srgb(0xFFFBF7), seal: srgb(0xB45B3E)
    )

    /// Falls back to `paper` for anything unknown, and accepts the legacy
    /// "dark" code. The Mac's resolver, word for word.
    static func theme(id: String) -> PaperTheme {
        switch id {
        case "night", "dark": return night
        case "slate": return slate
        case "moss": return moss
        case "clay": return clay
        default: return paper
        }
    }
}

/// Which paper is on screen, and the one place a change is announced.
///
/// A `Palette` alone cannot do this: its values are static, and SwiftUI only
/// re-reads a view when something it observes changes, so a theme picked in
/// 設定 would have written the setting and left every open screen in the old
/// colours until the app was restarted. The store is what the theme change is
/// published on; `Palette` reads through it.
///
/// "system" (the default, as on the Mac) resolves through the current
/// appearance, so a phone in dark mode gets 夜墨 without the user choosing.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// The chosen id, or "system".
    @Published private(set) var id: String
    /// What the OS is in right now. Kept here rather than asked of UIKit at
    /// read time because `Palette` is read from places (a share-sheet builder,
    /// a file writer) where there is no view and no trait collection.
    @Published var systemIsDark: Bool = false

    private init() { id = SharedStore.themeID }

    var theme: PaperTheme {
        guard id == "system" else { return PaperThemes.theme(id: id) }
        return systemIsDark ? PaperThemes.night : PaperThemes.paper
    }

    func select(_ id: String) {
        self.id = id
        SharedStore.themeID = id
    }

    /// Draws with `id` without recording it: the `-OVC_THEME` screenshot flag.
    /// Separate from `select` on purpose -- a run that exists to take a picture
    /// must not change what the tester chose.
    func preview(_ id: String) {
        self.id = id
    }
}

/// The palette the app draws with: five named colours, read from whichever
/// paper is selected.
enum Palette {
    static var current: PaperTheme { ThemeStore.shared.theme }

    static var ink: Color { current.ink }
    static var dim: Color { current.dim }
    static var paper: Color { current.paper }
    /// The card surface. Named `wash` because that is what it is: a wash of ink
    /// (or of paper, on the dark sheets) over the window behind it.
    static var wash: Color { current.wash }
    static var seal: Color { current.seal }
}

/// A titled group of rows, the phone's version of the Mac's card.
struct Card<Content: View>: View {
    let title: String?
    let caption: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            content
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The tab strip: five words, the current one underlined.
///
/// Same shape as the Mac's `TabStrip`, and the same reason: pills read as buttons
/// and the user cannot tell which one is the page they are on.
struct TabStrip: View {
    let titles: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    Text(titles[index])
                        .font(.system(size: 13, weight: index == selected ? .semibold : .regular))
                        .foregroundStyle(index == selected ? Palette.ink : Palette.dim)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(index == selected ? Palette.ink : .clear)
                                .frame(height: 1)
                                .offset(y: 4)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
