import SwiftUI
import UniformTypeIdentifiers

@main
struct OVCApp: App {
    init() {
        // Before any view exists, so a launch that never reaches one is still readable.
        Diagnostics.emit()
    }

    var body: some Scene {
        WindowGroup {
            if Diagnostics.isSmokeRun {
                SmokeView()
            } else {
                RootView()
            }
        }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published var recording = false
    @Published var text = ""
    @Published var partial = ""
    @Published var error: String?
    @Published var busy = false

    private let mic = MicCapture()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "ovc.asr", qos: .userInitiated)

    func start() {
        guard !recording, !busy else { return }
        error = nil
        busy = true
        queue.async {
            do {
                try Core.initialize(models: SharedStore.modelsDir)
                try Core.start()
                self.mic.onSamples = { Core.submit($0) }
                try self.mic.start()
                DispatchQueue.main.async {
                    self.busy = false
                    self.recording = true
                    self.text = ""
                    self.partial = ""
                    self.startPolling()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let segments = Core.segments()
                let open = Core.peek()
                guard !segments.isEmpty || !open.isEmpty else { return }
                DispatchQueue.main.async {
                    for s in segments { self.text += s.text }
                    self.partial = open
                }
            }
        }
    }

    func stop() {
        guard recording else { return }
        timer?.invalidate()
        timer = nil
        recording = false
        mic.stop()
        busy = true
        let accumulated = text
        queue.async {
            let final = (try? Core.stop()) ?? ""
            let out: String
            if final.isEmpty {
                out = accumulated
            } else if final.hasPrefix(accumulated) {
                out = final
            } else {
                out = accumulated + final
            }
            DispatchQueue.main.async {
                self.busy = false
                self.partial = ""
                self.text = out
                if !out.isEmpty { SharedStore.put(out) }
            }
        }
    }

    func clear() {
        text = ""
        partial = ""
        error = nil
    }
}

struct RootView: View {
    @StateObject private var recorder = Recorder()
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
            if url.host == "record" { recorder.start() }
        }
    }

    // MARK: recorder

    private var displayText: String {
        recorder.text + recorder.partial
    }

    private var recorderView: some View {
        VStack(spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("聽寫").font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(ink)
                Spacer()
                Text(recorder.recording ? "錄音中" : "待機")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(recorder.recording ? seal : dim)
            }
            .padding(.top, 12)

            ScrollView {
                Text(displayText.isEmpty ? "按下面的麥克風，說一句話。\n文字會出現在這裡，也會送到鍵盤。" : displayText)
                    .font(.system(size: 20, design: .serif))
                    .foregroundStyle(displayText.isEmpty ? dim : ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxHeight: .infinity)

            if let error = recorder.error {
                Text(error).font(.footnote).foregroundStyle(seal)
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
                    recorder.clear()
                } label: {
                    Label("清除", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButton())
                .disabled(displayText.isEmpty)
            }

            Button {
                recorder.recording ? recorder.stop() : recorder.start()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.recording ? seal : Color.white.opacity(0.10))
                        .frame(width: 86, height: 86)
                    if recorder.busy {
                        ProgressView().tint(ink)
                    } else {
                        Image(systemName: recorder.recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(recorder.recording ? Color.white : ink)
                    }
                }
            }
            .disabled(recorder.busy)
            .padding(.bottom, 8)

            Text("在 iPhone 上要這樣用：設定 › 一般 › 鍵盤 › 鍵盤 › 加入新的鍵盤 › 語音輸入，\n之後在任何輸入框切到它，按麥克風。")
                .font(.system(size: 11))
                .foregroundStyle(dim)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
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
