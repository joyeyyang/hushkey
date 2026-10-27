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
            Text("按 🌐 切到「語音輸入」。沒有字母鍵是刻意的：要打字就切回自己的鍵盤。")
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
    func makeUIView(context: Context) -> VoiceBar {
        let bar = VoiceBar()
        // Same states the extension shows, so the picture is not a mock-up: the
        // idle prompt is what a user sees before tapping, which is the one that
        // has to fit.
        bar.apply(phase: .idle, text: "", needsSwitch: true, paused: false)
        return bar
    }

    func updateUIView(_ bar: VoiceBar, context: Context) {}
}
