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
                VoiceBarPreview(expanded: true)
            }
        }
        .padding(20)
        .background(Color(red: 0.08, green: 0.07, blue: 0.065).ignoresSafeArea())
        .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.86))
        .onAppear {
            // Focusing in the same runloop pass is ignored; the field has to exist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }
}

/// The real keyboard bar, in the app, at real size.
struct VoiceBarPreview: UIViewRepresentable {
    /// Draws the 修改的提示詞 panel open, which is the state whose height and
    /// button row are otherwise only visible on a phone with the keyboard up.
    var expanded = false

    func makeUIView(context: Context) -> VoiceBar {
        let bar = VoiceBar()
        // Same states the extension shows, so the picture is not a mock-up: the
        // idle prompt is what a user sees before tapping, which is the one that
        // has to fit.
        bar.apply(phase: .idle, text: "", needsSwitch: true, paused: false)
        if expanded {
            bar.showEditPanel(prefill: "把三點改成四點")
            // The field must not take focus here: the probe screen already has
            // one, and a keyboard inside the app's own screen is not the picture
            // this is for.
            bar.endEditing(true)
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
            height: expanded ? VoiceBar.expandedHeight : VoiceBar.height
        )
    }
}
