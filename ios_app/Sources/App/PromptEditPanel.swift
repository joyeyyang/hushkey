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

/// The 修改提示詞 panel: the instruction, the region, and one button.
///
/// Deliberately NOT part of the AI 整理 switch above it. 整理 is the default
/// cleanup every sentence gets; this is a second pass the user asks for, with
/// their own words, on a region they chose. Sharing the prompt would make one
/// of the two do the other's job -- and the core keeps them apart on purpose
/// (`REFINE_SYSTEM` vs `EDIT_SYSTEM`).
struct PromptEditPanel: View {
    @ObservedObject var dictation: DictationController
    /// The transcript's selected range, as the text view reported it.
    let selection: NSRange
    /// The sentence on screen, which is what a region is measured against.
    let text: String

    @StateObject private var runner = PromptEditRunner()
    @State private var instruction = ""
    @State private var region: PromptEditRegion = .whole
    @State private var line = 1
    @State private var result: String?

    private var lines: [String] { PromptEdit.lines(of: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("修改提示詞")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("改哪一段、怎麼改")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
            }

            HStack(spacing: 8) {
                TextField("例：改成禮拜五下午兩點", text: $instruction)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 11)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
                    .submitLabel(.done)
                    .onSubmit(run)

                Button(action: run) {
                    if runner.running {
                        ProgressView().tint(Palette.ink)
                            .frame(width: 58, height: 36)
                    } else {
                        Text("執行修改")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 58, height: 36)
                    }
                }
                .buttonStyle(.plain)
                .background(Palette.seal.opacity(instruction.isEmpty ? 0.25 : 0.55),
                            in: RoundedRectangle(cornerRadius: 9))
                // Never disabled: the reason it cannot run is shown instead, so
                // the button never becomes a control that does nothing.
                .opacity(instruction.isEmpty || runner.running ? 0.6 : 1)
            }

            regionPicker

            if let error = runner.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.seal)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = runner.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result {
                Text("已修改。按上面的「複製」可以貼回原本的輸入框。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                Text(result)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: text) { _, _ in
            // A new sentence makes the old line number and the old result
            // meaningless. The instruction is the user's and stays.
            line = 1
            result = nil
            if region == .selection { region = .whole }
        }
    }

    /// 整段 / 選取範圍 / 第 N 行, as flat words with the current one underlined --
    /// the same shape as the mode switch, rather than a third kind of control on
    /// one screen.
    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                regionButton(.whole)
                regionButton(.selection)
                regionButton(.line(max(1, min(line, max(1, lines.count)))))
            }
            if case .line = region {
                HStack(spacing: 10) {
                    stepButton("minus") { line = max(1, line - 1) }
                    Text(linePreview)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stepButton("plus") { line = min(max(1, lines.count), line + 1) }
                }
            } else if region == .selection {
                Text(selectionText)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func regionButton(_ target: PromptEditRegion) -> some View {
        // The line button carries the live number, so its identity changes as
        // the stepper moves; comparing by case keeps the underline steady.
        let active: Bool
        switch (region, target) {
        case (.whole, .whole), (.selection, .selection): active = true
        case (.line, .line): active = true
        default: active = false
        }
        return Button {
            switch target {
            case .whole: region = .whole
            case .selection: region = .selection
            case .line: region = .line(max(1, min(line, max(1, lines.count))))
            }
        } label: {
            Text(target.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Palette.ink : Palette.dim)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? Palette.ink : .clear)
                        .frame(height: 1)
                        .offset(y: 3)
                }
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 26, height: 22)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var linePreview: String {
        let items = lines
        guard items.indices.contains(line - 1) else { return "這一段沒有第 \(line) 行" }
        return "第 \(line) 行：\(items[line - 1])"
    }

    private var selectionText: String {
        guard let range = Range(selection, in: text), !range.isEmpty else {
            return "在文字上按住拖曳，選出要改的那一段。"
        }
        return "已選取：\(text[range])"
    }

    private func run() {
        guard !runner.running else { return }
        let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            runner.reject(PromptEditError.emptyInstruction.errorDescription ?? "")
            return
        }
        let target = text
        let range = Range(selection, in: target)
        runner.run(text: target, instruction: typed, region: region, selection: range) { edited in
            result = edited
            dictation.replaceTranscript(edited)
        }
    }
}

