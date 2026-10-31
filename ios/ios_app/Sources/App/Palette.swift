import SwiftUI
import UIKit

/// The app's colours, in one place: green, and only green.
///
/// There used to be five papers here (米白紙／夜墨／石板／苔綠／陶土) copied hex for
/// hex from the Mac's `Theme.swift`, plus a picker in 設定 and a `ThemeStore` to
/// publish the change. The user's instruction was to drop all of that: every colour
/// setting is green and there is nothing to choose. So this file went back to being
/// what it was before that work — six static values — with the hue moved to green.
///
/// The values themselves are chosen for contrast rather than for taste: body text
/// on the paper is ~13:1, captions are ~4.6:1, and the seal (the accent: the
/// recording ring, toggles, the AI 整理 switch's on state) is dark enough to carry
/// white text at ~5.9:1. Green is the requirement; readable is not optional.
enum Palette {
    /// Body text. Near-black with a green cast, so it reads as ink on this paper
    /// rather than as a neutral grey that happens to sit on it.
    static let ink = Color(red: 0.086, green: 0.145, blue: 0.106)      // #16251B
    /// Captions and anything that must recede.
    static let dim = Color(red: 0.361, green: 0.420, blue: 0.376)      // #5C6B60
    /// The window behind everything.
    static let paper = Color(red: 0.949, green: 0.969, blue: 0.949)    // #F2F7F2
    /// Cards and inset areas: a shade off the paper, so one wash works over light
    /// and dark surfaces alike.
    static let wash = Color(red: 0.894, green: 0.929, blue: 0.898)     // #E4EDE5
    /// The accent. The one saturated green in the app.
    static let seal = Color(red: 0.180, green: 0.490, blue: 0.196)     // #2E7D32
    /// The keyboard extension's own chrome. A keyboard is not this window: it draws
    /// on the system's dark keyboard background, so its greens are the same greens
    /// against a dark sheet instead of a light one.
    static let keyboardBackground = UIColor(red: 0.055, green: 0.098, blue: 0.067, alpha: 1) // #0E1911
    static let keyboardInk = UIColor(red: 0.882, green: 0.929, blue: 0.886, alpha: 1)         // #E1EDE2
    static let keyboardDim = UIColor(red: 0.576, green: 0.647, blue: 0.584, alpha: 1)         // #93A595
    static let keyboardSeal = UIColor(red: 0.259, green: 0.663, blue: 0.278, alpha: 1)        // #42A947
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
