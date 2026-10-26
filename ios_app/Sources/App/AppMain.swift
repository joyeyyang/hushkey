import SwiftUI
import UniformTypeIdentifiers

@main
struct OVCApp: App {
    init() {
        // Before any view exists, so a launch that never reaches one is still readable.
        Diagnostics.emit()

        // `-OVC_AUDIO_FILE <path>` runs the whole pipeline over a file instead of
        // the microphone. The simulator has no usable microphone, and everything
        // after the sample buffer is the part worth testing.
        if let path = Diagnostics.injectedAudio {
            Task { @MainActor in
                DictationController.shared.prewarm()
                // Lets a text field take focus (and the keyboard appear) first.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                DictationController.shared.runInjected(url: URL(fileURLWithPath: path))
            }
        } else if Diagnostics.startsRecording {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                DictationController.shared.start()
            }
        }
    }

    private static var isKeyboardProbe: Bool {
        ProcessInfo.processInfo.arguments.contains("-OVC_KB_PROBE")
    }

    var body: some Scene {
        WindowGroup {
            if Diagnostics.isSmokeRun {
                SmokeView()
            } else if Self.isKeyboardProbe {
                KeyboardProbeView()
            } else {
                RootView()
            }
        }
    }
}

struct RootView: View {
    @ObservedObject private var dictation = DictationController.shared
    @State private var modelsReady = SharedStore.hasModels
    @State private var importing = false
    @State private var copied = false

    private let ink = Color(red: 0.93, green: 0.90, blue: 0.86)
    private let dim = Color(red: 0.58, green: 0.55, blue: 0.51)
    private let paper = Color(red: 0.08, green: 0.07, blue: 0.065)
    private let seal = Color(red: 0.76, green: 0.27, blue: 0.18)

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            if modelsReady {
                recorderView
            } else {
                modelsView
            }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            // The keyboard's microphone button. Cold launch and re-entry both
            // land here, and both should start recording immediately.
            if url.host == "record", modelsReady { dictation.start() }
        }
        .onAppear {
            guard modelsReady else { return }
            dictation.prewarm()
            // Audio from a run the system killed before it could publish.
            dictation.recoverOrphan()
        }
    }

    // MARK: recorder

    private var displayText: String { dictation.display }

    private var statusWord: String {
        switch dictation.phase {
        case .recording: return "錄音中"
        case .transcribing: return "辨識中"
        case .refining: return "整理中"
        case .done: return "完成"
        case .failed: return "錯誤"
        case .idle: return "待機"
        }
    }

    private var statusColor: Color {
        switch dictation.phase {
        case .recording, .failed: return seal
        case .done: return ink
        default: return dim
        }
    }

    private var recorderView: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("聽寫").font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(ink)
                Spacer()
                Text(statusWord)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.top, 12)

            ScrollView {
                Text(displayText.isEmpty ? emptyHint : displayText)
                    .font(.system(size: 20, design: .serif))
                    .foregroundStyle(displayText.isEmpty ? dim : ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxHeight: .infinity)

            if let error = dictation.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(seal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if dictation.phase == .done {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("已送到鍵盤。點左上「◀ 上一個 App」回去，字會在游標出現。")
                        .font(.system(size: 12))
                }
                .foregroundStyle(ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = displayText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "已複製" : "複製", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButton())
                .disabled(displayText.isEmpty)

                Button {
                    dictation.clear()
                } label: {
                    Label("清除", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButton())
                .disabled(displayText.isEmpty && dictation.phase == .idle)
            }

            Button {
                if dictation.isRecording {
                    dictation.stop()
                } else {
                    dictation.start()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(dictation.isRecording ? seal : Color.white.opacity(0.10))
                        .frame(width: 86, height: 86)
                    if dictation.isBusy && !dictation.isRecording {
                        ProgressView().tint(ink)
                    } else {
                        Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(dictation.isRecording ? Color.white : ink)
                    }
                }
            }
            .disabled(dictation.isBusy && !dictation.isRecording)
            .padding(.bottom, 4)

            Text("在 iPhone 上要這樣用：設定 › 一般 › 鍵盤 › 鍵盤 › 加入新的鍵盤 › 語音輸入，\n之後在任何輸入框切到它，按麥克風。停下來 1 秒會自動停止。")
                .font(.system(size: 11))
                .foregroundStyle(dim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
    }

    private var emptyHint: String {
        switch dictation.phase {
        case .recording: return "請開始說話。"
        case .transcribing: return "辨識中…"
        default: return "按下面的麥克風，說一句話。\n文字會出現在這裡，也會送到鍵盤。"
        }
    }

    // MARK: models

    private var modelsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("還沒有語音模型").font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(ink)
            Text("這台裝置上找不到 Dolphin 辨識模型。選一個含 `asr/` 的 models 資料夾，它會被複製進 App。")
                .font(.system(size: 14)).foregroundStyle(dim)

            Button("選擇 models 資料夾") { importing = true }
                .buttonStyle(QuietButton())

            Text(SharedStore.modelsDir.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(dim)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            importModels(from: url)
        }
    }

    private func importModels(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = SharedStore.modelsDir
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let target = dest.appendingPathComponent(item.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: item, to: target)
            }
            DispatchQueue.main.async { modelsReady = SharedStore.hasModels }
        }
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.86))
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07),
                        in: RoundedRectangle(cornerRadius: 10))
    }
}
