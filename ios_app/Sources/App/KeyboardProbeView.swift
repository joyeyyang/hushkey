import SwiftUI

/// A text field for testing the keyboard, reachable only with `-OVC_KB_PROBE`.
///
/// The keyboard only appears when something wants text, and the app's own screen
/// has none. This gives a place to switch keyboards and watch the session handoff
/// without involving a third-party app.
struct KeyboardProbeView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("鍵盤測試")
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text("按 🌐 切到「語音輸入」，再按左邊的麥克風。")
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
