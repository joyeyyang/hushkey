import SwiftUI

/// The app's one palette, in one place.
///
/// Flat on purpose: no capsules, no glass, no gradients. The Mac's window is paper
/// with ink on it, and the phone screens are the same ink on a darker paper so the
/// two read as one product. Every view pulls from here rather than repeating the
/// numbers, which is what stopped the recorder and the model screen from drifting
/// into two slightly different greys.
enum Palette {
    static let ink = Color(red: 0.93, green: 0.90, blue: 0.86)
    static let dim = Color(red: 0.58, green: 0.55, blue: 0.51)
    static let paper = Color(red: 0.08, green: 0.07, blue: 0.065)
    static let seal = Color(red: 0.76, green: 0.27, blue: 0.18)
    /// The flat card a group of rows sits on. `Color.white.opacity` rather than a
    /// literal so it stays a wash over whatever paper is behind it.
    static let wash = Color.white.opacity(0.04)
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
