import SwiftUI

/// A text field for testing the keyboard, reachable only with `-OVC_KB_PROBE`.
///
/// The keyboard only appears when something wants text, and the app's own screen
/// has none. This gives a place to switch keyboards and watch the session handoff
/// without involving a third-party app.
///
/// The real `VoiceBar` is drawn underneath it. That is the point of the screen now:
/// the bar is the whole keyboard, and a screenshot of it on a machine is how its
/// layout gets checked — the alternative is finding out on a phone that the
/// transcript is clipped.
struct KeyboardProbeView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // `-OVC_KB_PROBE_PANEL` / `-OVC_KB_PROBE_CONFIRM` draw one expanded bar on
        // its own, at real size. They exist because the system keyboard covers the
        // bottom of this screen -- and a keyboard extension cannot dismiss it -- so
        // an expanded bar is otherwise only visible on a phone.
        if let solo = soloPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text(soloLabel(solo))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VoiceBarPreview(state: solo)
                Spacer()
            }
            .padding(20)
            .background(Color(red: 0.08, green: 0.07, blue: 0.065).ignoresSafeArea())
            .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.86))
        } else {
            fullProbe
        }
    }

    private func soloLabel(_ state: VoiceBarPreview.State) -> String {
        switch state {
        case .confirm: return "貼上前確認（按「插入」前的樣子）"
        case .recording: return "錄音中：這一顆是停止，不是麥克風"
        case .editPanel, .idle: return "按鉛筆後的樣子（修改的提示詞）"
        }
    }

    private var soloPanel: VoiceBarPreview.State? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-OVC_KB_PROBE_CONFIRM") { return .confirm }
        if args.contains("-OVC_KB_PROBE_RECORDING") { return .recording }
        if args.contains("-OVC_KB_PROBE_PANEL") { return .editPanel }
        return nil
    }

    private var fullProbe: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("鍵盤測試")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("按 🌐 切到「Hushkey」。沒有字母鍵是刻意的：要打字就切回自己的鍵盤。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 18, design: .serif))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)

            HStack {
                Button("清空") { text = "" }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(text.count) 字")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("鍵盤上的那一條（實機/模擬器切到本鍵盤時看到的就是這個）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VoiceBarPreview()
                Text("按鉛筆後的樣子（修改的提示詞）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VoiceBarPreview(state: .editPanel)
            }
        }
        .padding(20)
        .background(Color(red: 0.08, green: 0.07, blue: 0.065).ignoresSafeArea())
        .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.86))
        .onAppear {
            // Focusing in the same runloop pass is ignored; the field has to exist.
            // `-OVC_KB_PROBE_NOFOCUS` draws the screen without the system
            // keyboard, which is the only way to photograph the 修改的提示詞
            // preview underneath it (the keyboard covers the bottom half).
            guard !ProcessInfo.processInfo.arguments.contains("-OVC_KB_PROBE_NOFOCUS") else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }
}

/// The real keyboard bar, in the app, at real size.
struct VoiceBarPreview: UIViewRepresentable {
    /// Which state to draw. All of them exist in the extension and none of them can
    /// be reached from this screen -- the probe is a photograph, not a demo.
    enum State {
        /// What the user sees before tapping.
        case idle
        /// 修改的提示詞 open: the height and the button row are otherwise only
        /// visible on a phone with the keyboard up.
        case editPanel
        /// 貼上前確認 holding a sentence.
        case confirm
        /// Mid-dictation: the microphone is a stop button and the words are live.
        case recording
    }

    var state: State = .idle

    func makeUIView(context: Context) -> VoiceBar {
        let bar = VoiceBar()
        // Same states the extension shows, so the picture is not a mock-up: the
        // idle prompt is what a user sees before tapping, which is the one that
        // has to fit.
        bar.apply(phase: .idle, text: "", needsSwitch: true, paused: false)
        switch state {
        case .idle:
            break
        case .editPanel:
            bar.showEditPanel(prefill: "把三點改成四點")
            // The field must not take focus here: the probe screen already has
            // one, and a keyboard inside the app's own screen is not the picture
            // this is for. Resigning has to happen after the view joins the
            // window, which is where `becomeFirstResponder` finally takes.
            DispatchQueue.main.async { bar.endEditing(true) }
        case .confirm:
            bar.showConfirmPanel(text: "下週一上午十點前把預算表寄給王經理，副本給財務部。")
        case .recording:
            // The state that used to end itself. The microphone is a stop button
            // here, and this is the only picture of it that does not need a phone.
            bar.apply(
                phase: .recording,
                text: "下週一上午十點前把預算表寄給王經理，副本給財務部。",
                needsSwitch: false,
                paused: false
            )
        }
        return bar
    }

    func updateUIView(_ bar: VoiceBar, context: Context) {}

    /// The bar's height is a constraint inside the view, and SwiftUI does not read
    /// it -- without this, two previews in one column were given a shared slice of
    /// the screen and drew on top of each other.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: VoiceBar, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIScreen.main.bounds.width,
            height: state == .idle ? VoiceBar.height : VoiceBar.expandedHeight
        )
    }
}
