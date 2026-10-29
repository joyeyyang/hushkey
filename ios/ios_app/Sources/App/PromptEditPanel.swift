import SwiftUI

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
    @State private var kind: RegionKind = .whole
    @State private var line = 1
    @State private var result: String?

    private var lines: [String] { PromptEdit.lines(of: text) }

    /// The three segments. The line number rides beside this, not inside it.
    private enum RegionKind: Hashable { case whole, line, selection }

    /// What is handed to the core. The line case clamps, so a stepper that ran
    /// past the end can never produce a "第 9 行" for a three-line sentence --
    /// which the core would read as a position it cannot find.
    private var region: PromptEditRegion {
        switch kind {
        case .whole: return .whole
        case .line: return .line(max(1, min(line, max(1, lines.count))))
        case .selection: return .selection
        }
    }

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
            if kind == .selection { kind = .whole }
        }
    }

    /// 整段 / 第 N 行 / 選取範圍, as a segmented control.
    ///
    /// A `Picker` rather than three custom buttons: these are mutually exclusive
    /// options, which is what the control means. The line number is deliberately
    /// NOT part of the selection's identity -- otherwise every step of the
    /// stepper would rebuild the picker and the segment would flicker.
    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("區域", selection: $kind) {
                Text("整段").tag(RegionKind.whole)
                Text("第 N 行").tag(RegionKind.line)
                Text("選取範圍").tag(RegionKind.selection)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .whole:
                Text("整段交給 AI 改寫。轉換型的指令（例如「改短一點」）走這條。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            case .line:
                HStack(spacing: 10) {
                    stepButton("minus") { line = max(1, line - 1) }
                    Text(linePreview)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stepButton("plus") { line = min(max(1, lines.count), line + 1) }
                }
            case .selection:
                Text(selectionText)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

