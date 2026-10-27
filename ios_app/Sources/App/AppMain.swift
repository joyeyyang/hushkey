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

        // `-OVC_MERGE_PROBE`: the overlapping-transcript rule, over the exact
        // pair that produced a doubled sentence -- the two sides of the pipeline
        // spell the same words differently when a boundary is not Chinese to
        // Chinese (the core inserts a space, this side concatenates), and the old
        // code appended them. A dictation cannot reproduce it on this recogniser,
        // which normalises English and digits to Chinese, so the rule is checked
        // directly rather than through audio that will not exercise it.
        if ProcessInfo.processInfo.arguments.contains("-OVC_MERGE_PROBE") {
            let pairs = [
                ("開會用Notion記錄", "開會用 Notion 記錄"),
                ("今天下午三點要開會", "今天下午三點要開會"),
                ("", "只有核心的話"),
                ("只有這一邊", ""),
            ]
            for (accumulated, final) in pairs {
                Diagnostics.log.notice(
                    "merge: \(DictationController.merge(accumulated, final), privacy: .public)"
                )
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
    @State private var showingModels = false
    @State private var mode = SharedStore.mode
    /// What Mode 2 has to say when it cannot run on this device.
    @State private var modeNotice: String?
    @State private var copied = false
    @State private var refine = SharedStore.refineEnabled

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
        .sheet(isPresented: $showingModels) {
            ZStack {
                paper.ignoresSafeArea()
                modelsView
            }
            .preferredColorScheme(.dark)
        }
        .onOpenURL { url in
            // The keyboard's microphone button. Cold launch and re-entry both
            // land here, and both should start recording immediately.
            if url.host == "record", modelsReady { dictation.start() }
        }
        .onAppear {
            // A launch is proof that no PiP window from a previous run survived:
            // the delegate that clears this flag never runs in a process the
            // system kills, and a stale `true` is what turns the keyboard's
            // microphone into a button that records nothing.
            SharedStore.pipLive = false
            // Before any check: the model screen's whole point is to be a place
            // the user can put something, so the folders exist first and the
            // status is recomputed from what is actually on disk.
            SharedStore.prepareModelDirs()
            modelsReady = SharedStore.hasModels
            // Mode 2's trigger: the keyboard asks over the group, and nothing
            // switches apps.
            SharedStore.observeRecordRequest { [dictation] in
                guard SharedStore.mode == .pip else { return }
                dictation.start()
            }
            // Launch flag: the simulator cannot be tapped from a script, and
            // "does this device support PiP at all" is exactly the question that
            // needs an answer on paper rather than in a comment.
            if ProcessInfo.processInfo.arguments.contains("-OVC_PIP_PROBE") {
                mode = .pip
                SharedStore.mode = .pip
                Diagnostics.log.notice("pip probe: requested at launch")
                // The anchor view is installed during the first layout pass,
                // which can land after `onAppear`; one turn of the run loop later
                // it is there.
                DispatchQueue.main.async { startPiP() }
            }
            guard modelsReady else { return }
            // The screen's own 清除 button, reachable from a launch flag because a
            // simulator cannot be tapped from a script. It exercises the real
            // action, which is what makes the check worth running.
            if ProcessInfo.processInfo.arguments.contains("-OVC_CLEAR") {
                // Three seconds, not immediately: with a spool left by a killed
                // run, recovery has started by then, which is the case worth
                // testing -- 清除 during recovery must stop it rather than let the
                // sentence arrive anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Diagnostics.log.notice("clear requested at launch")
                    dictation.clear()
                }
            }
            // A phase left behind by a process the system killed reads as a
            // dictation still in progress, and the keyboard then shows a stop
            // button for something that will never finish.
            let left = SharedStore.current().phase
            if left == .recording || left == .transcribing || left == .refining {
                SharedStore.setPhase(.idle, detail: "上次的聽寫沒有完成")
            }
            dictation.prewarm()
            // Audio from a run the system killed before it could publish. Waiting
            // one and a half seconds is deliberate: a cold launch from the
            // keyboard's microphone arrives through `onOpenURL` right after this,
            // and recovering first would take the microphone for twenty seconds
            // while the user talks into a dictation that never started.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [dictation] in
                guard dictation.phase == .idle else { return }
                dictation.recoverOrphan()
            }
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
                // An icon, not the word "模型": the status word beside it can be
                // the word 完成 too, and two of them read as two buttons.
                Button {
                    showingModels = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(dim)
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

            // The same switch the desktop has, and the same default: the cleanup
            // pass is what makes a transcript readable to someone else, so it is on
            // until a user says otherwise.
            Toggle(isOn: Binding(
                get: { refine },
                set: { refine = $0; SharedStore.refineEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text("AI 整理").font(.system(size: 13))
                    Text("標點、去贅字、保留原意")
                        .font(.system(size: 11))
                        .foregroundStyle(dim)
                }
            }
            .tint(seal)
            .disabled(dictation.isBusy)

            // Mode 1 / Mode 2. Flat, two words, current one underlined -- the
            // same shape as the rest of this screen rather than a segmented
            // control.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    modeButton("跳回 App", .toApp)
                    modeButton("留在原 App（小窗）", .pip)
                }
                if let modeNotice {
                    Text(modeNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(seal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

    // MARK: pip

    private func modeButton(_ title: String, _ target: SharedStore.Mode) -> some View {
        Button {
            mode = target
            SharedStore.mode = target
            if target == .pip {
                startPiP()
            } else {
                PiPController.shared.stop()
                modeNotice = nil
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: mode == target ? .semibold : .regular))
                .foregroundStyle(mode == target ? ink : dim)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(mode == target ? ink : .clear)
                        .frame(height: 1)
                        .offset(y: 3)
                }
        }
        .buttonStyle(.plain)
    }

    /// Starts the PiP window, and says so in the UI when the device will not.
    ///
    /// Silence here is the failure mode worth preventing: a user who picks "stay
    /// in the other app" and gets a microphone button that does nothing has no
    /// way to tell whether they mis-tapped or the device refused.
    private func startPiP() {
        Diagnostics.log.notice("pip: start requested")
        // PiP anchors to a view that is on screen, and the key window is exactly
        // that whenever the user can tap the switch. Reading it here rather than
        // threading a SwiftUI placeholder through state removes a hand-off that
        // has no failure mode worth owning.
        let host = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }
        guard let anchor = host else {
            Diagnostics.log.error("pip: no key window yet; Mode 2 deferred")
            modeNotice = "小窗還沒準備好，稍後再試一次。"
            return
        }
        guard PiPController.isSupported else {
            // The simulator is the usual reason, and it is not a bug to work
            // around: no call-style PiP there, so Mode 2 cannot be demonstrated
            // off-device. Say it in the log rather than only on screen.
            Diagnostics.log.error("pip: unsupported on this device; falling back to Mode 1")
            modeNotice = "這台裝置不支援小窗（PiP），已改回跳回 App。"
            mode = .toApp
            SharedStore.mode = .toApp
            return
        }
        PiPController.shared.start(in: anchor)
        modeNotice = "小窗會在本 App 切到背景後出現。"
    }

    // MARK: models

    private var modelsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("模型").font(.system(size: 26, weight: .semibold, design: .serif))
                        .foregroundStyle(ink)
                    Spacer()
                    // Reachable from the recorder too, so a model can be replaced
                    // -- or a downgrade reviewed -- without uninstalling anything.
                    if SharedStore.hasModels {
                        Button("完成") { showingModels = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundStyle(dim)
                    }
                }
                Text(SharedStore.hasModels
                     ? "辨識模型與 AI 整理模型都只留在這台裝置上。"
                     : "辨識模型是必要的，AI 整理模型是選用的。兩者都只留在這台裝置上。")
                    .font(.system(size: 14)).foregroundStyle(dim)

                modelRow(
                    title: "辨識模型",
                    detail: "asr/dolphin/model.int8.onnx 與 tokens.txt",
                    ready: SharedStore.hasModels,
                    required: true
                )
                modelRow(
                    title: "AI 整理模型",
                    detail: "llm/ 裡放一個 .gguf（預設 \(LLMPolicy.preferredName)）",
                    ready: SharedStore.hasLLM,
                    required: false
                )

                Button("選擇檔案或資料夾匯入") { importing = true }
                    .buttonStyle(QuietButton())

                if let downgrade = LLMPolicy.recorded {
                    // A downgrade is a decision the app made on the user's behalf,
                    // so it has to be visible and reversible -- otherwise "the AI
                    // cleanup got worse" has no explanation anywhere.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI 整理已降級")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ink)
                        Text("\(downgrade.from) → \(downgrade.to)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(dim)
                        Text(downgrade.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(dim)
                        Button("重新嘗試大模型") {
                            LLMPolicy.clear()
                            modelsReady = SharedStore.hasModels
                        }
                        .buttonStyle(QuietButton())
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(seal.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                // The path a phone can actually reach. On a device the importer
                // is the only way in *while the app is open*; with file sharing
                // on, Finder and the Files app write to the same folder with the
                // app closed, which is what makes a 100 MB model installable
                // without a cable and Xcode.
                VStack(alignment: .leading, spacing: 6) {
                    Text("也可以用 Finder 或「檔案」App 放進去")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                    Text("我的 iPhone › 語音輸入 › models\n（asr/ 與 llm/ 兩個資料夾已經建好了）")
                        .font(.system(size: 12))
                        .foregroundStyle(dim)
                    Text(SharedStore.modelsRoot.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(dim)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder, .data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            importModels(from: urls)
        }
    }

    private func modelRow(title: String, detail: String, ready: Bool, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : (required ? "circle.dashed" : "circle"))
                .font(.system(size: 15))
                .foregroundStyle(ready ? ink : dim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                    Text(ready ? "已安裝" : (required ? "未安裝" : "未安裝 · 選用"))
                        .font(.system(size: 11))
                        .foregroundStyle(dim)
                }
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(dim)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Copies whatever the user picked into the model tree.
    ///
    /// Three shapes arrive here and the UI cannot tell them apart beforehand: a
    /// `models/` folder to merge, an `asr/` or `llm/` folder to drop in place, or
    /// loose files. The extension is the only reliable classifier for the loose
    /// ones, so it decides -- a `.gguf` filed under `asr/` would simply never be
    /// found again.
    /// Which recogniser folder a loose file belongs in.
    ///
    /// The extension alone cannot answer this, and guessing wrong is not a
    /// cosmetic mistake: a Dolphin model dropped into `asr/` is loaded as
    /// SenseVoice (and vice versa), which fails at the first dictation with a
    /// message about the model rather than about the folder. Two facts decide it,
    /// and both come from how these two models are actually distributed:
    ///
    /// * Dolphin always ships inside a folder named `dolphin/`, so a file whose
    ///   source path says dolphin is one.
    /// * SenseVoice is two files directly under `asr/`, and `model.int8.onnx` is
    ///   its name. Nothing else is claimed, so an unrecognised `.onnx` goes to
    ///   `asr/` -- the recogniser the core prefers.
    ///
    /// A `tokens.txt` picked on its own follows whichever recogniser is already
    /// installed, so repairing a half-installed one does not create the other.
    private func recogniserDir(for url: URL, under dest: URL) -> URL {
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let name = url.lastPathComponent.lowercased()
        let dolphin = dest.appendingPathComponent("asr/dolphin", isDirectory: true)
        let sense = dest.appendingPathComponent("asr", isDirectory: true)

        if parent.contains("dolphin") { return dolphin }
        if name == "tokens.txt" || name.hasSuffix(".json") {
            let manager = FileManager.default
            let dolphinModel = manager.fileExists(atPath: dolphin.appendingPathComponent("model.int8.onnx").path)
            let senseModel = manager.fileExists(atPath: sense.appendingPathComponent("model.int8.onnx").path)
            if dolphinModel && !senseModel { return dolphin }
            return sense
        }
        return sense
    }

    private func importModels(from urls: [URL]) {
        let dest = SharedStore.modelsDir
        DispatchQueue.global(qos: .userInitiated).async {
            SharedStore.prepareModelDirs()
            let manager = FileManager.default

            func contents(_ dir: URL) -> [URL] {
                (try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            }

            func copy(_ from: URL, _ to: URL) {
                try? manager.removeItem(at: to)
                try? manager.copyItem(at: from, to: to)
            }

            func place(_ url: URL) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDir else {
                    switch url.pathExtension.lowercased() {
                    case "gguf":
                        copy(url, dest.appendingPathComponent("llm").appendingPathComponent(url.lastPathComponent))
                    case "onnx", "txt", "json":
                        let target = recogniserDir(for: url, under: dest)
                        copy(url, target.appendingPathComponent(url.lastPathComponent))
                    default:
                        break
                    }
                    return
                }

                let name = url.lastPathComponent
                if name == "asr" || name == "llm" {
                    // Picked the tree itself: its contents go in beside the
                    // existing ones rather than one level deeper.
                    for item in contents(url) {
                        copy(item, dest.appendingPathComponent(name).appendingPathComponent(item.lastPathComponent))
                    }
                } else {
                    // `models/`, or any folder the user made: descend.
                    for item in contents(url) {
                        place(item)
                    }
                }
            }

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                place(url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }

            DispatchQueue.main.async {
                modelsReady = SharedStore.hasModels
                if modelsReady { dictation.prewarm() }
            }
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
