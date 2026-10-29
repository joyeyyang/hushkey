import SwiftUI
import UIKit

/// The 轉錄 page's transcript, made selectable so a region can be named.
///
/// SwiftUI's `Text` + `.textSelection(.enabled)` lets the user select and copy,
/// but gives the app no way to read WHAT was selected -- and 「目前選取範圍」 is
/// one of the three regions the 修改提示詞 button offers. A `UITextView` reports
/// its range, so the region the user pointed at is the region the core is
/// handed instead of a guess made from the whole sentence.
///
/// Not editable: the text on this page is the sentence the app produced. The
/// user changes it with a 修改提示詞, which is the whole point of the panel
/// below -- an editable field here would be a second, silent way to edit that
/// bypasses the model and never reaches the history.
struct SelectableTranscript: UIViewRepresentable {
    let text: String
    let placeholder: String
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> GrowingTextView {
        let view = GrowingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: GrowingTextView, context: Context) {
        context.coordinator.parent = self
        let shown = text.isEmpty ? placeholder : text
        if view.text != shown {
            view.text = shown
            // The old range belongs to a sentence that is no longer there.
            view.selectedRange = NSRange(location: 0, length: 0)
            selection = view.selectedRange
            view.invalidateIntrinsicContentSize()
        }
        view.font = Self.font
        view.textColor = text.isEmpty ? UIColor(Palette.dim) : UIColor(Palette.ink)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The Mac's transcript face, one size down: serif, because the sentence is
    /// something to read rather than a form field.
    static let font: UIFont = {
        let base = UIFont.systemFont(ofSize: 20)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: 20)
    }()

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTranscript

        init(parent: SelectableTranscript) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Reported on every caret move, so a tap that only places the caret
            // (length 0) clears the region rather than leaving a stale one.
            guard parent.selection != textView.selectedRange else { return }
            parent.selection = textView.selectedRange
        }
    }
}

/// A `UITextView` that reports its own height.
///
/// `isScrollEnabled = false` alone does not give a usable intrinsic size inside
/// a SwiftUI `ScrollView` on every iOS version; the width is only known after
/// layout, so the size is recomputed when it changes.
final class GrowingTextView: UITextView {
    private var lastWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

