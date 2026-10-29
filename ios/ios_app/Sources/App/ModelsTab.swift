import SwiftUI
import UniformTypeIdentifiers

/// The 模型 tab: what is installed, how to put more there, and how to undo a
/// downgrade.
///
/// The Mac's model manager, on a phone: the same manifest, the same size and
/// SHA-256 checks, and the same 下載 button — plus the two routes a phone has that a
/// Mac does not need (Finder/Files with file sharing on, and the document picker).
///
/// Whatever gets the files here, this screen's job is to say *what is here*, *what
/// the engine will actually load*, and *what happened to the model choice* — the
/// three things that turn "the AI stopped working" into an answer.
struct ModelsTab: View {
    @Binding var ready: Bool
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var downloads = ModelDownloads.shared
    @State private var importing = false
    @State private var busy = false
    /// The manifest, read once: it is a file in this bundle, not something that
    /// changes while the screen is up.
    @State private var manifest = ModelManifest.items()
    /// The last verification per item, from 驗證. A dictionary rather than one
    /// slot: the point of checking is comparing two entries, and one result at a
    /// time overwrites the first before it has been read.
    @State private var verdicts: [String: ModelManifest.Verdict] = [:]
    /// The item being hashed right now. Hashing 1.3 GB takes a visible moment and
    /// happens off the main thread, so the row has to say so.
    @State private var checking: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ready
                     ? "辨識模型與 AI 整理模型都只留在這台裝置上。"
                     : "辨識模型是必要的，AI 整理模型是選用的。兩者都只留在這台裝置上。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.dim)

                modelRow(
                    title: "辨識模型",
                    detail: recogniserDetail,
                    ready: SharedStore.hasModels,
                    required: true
                )
                modelRow(
                    title: "AI 整理模型",
                    detail: "llm/ 裡放一個 .gguf（預設 \(LLMPolicy.preferredName)）",
                    ready: SharedStore.hasLLM,
                    required: false
                )

                downloadCard

                Button(busy ? "匯入中…" : "選擇檔案或資料夾匯入") { importing = true }
                    .buttonStyle(QuietButton())
                    .disabled(busy)

                if let downgrade = LLMPolicy.recorded {
                    // A downgrade is a decision the app made on the user's behalf,
                    // so it has to be visible and reversible -- otherwise "the AI
                    // cleanup got worse" has no explanation anywhere.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI 整理已降級")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("\(downgrade.from) → \(downgrade.to)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.dim)
                        Text(downgrade.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.dim)
                        Button("重新嘗試大模型") {
                            LLMPolicy.clear()
                        }
                        .buttonStyle(QuietButton())
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.seal.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let installed = installedLLMs, !installed.isEmpty {
                    Card("這台裝置上的語言模型",
                         caption: "引擎預設挑最大的那一份；降級紀錄會覆蓋這個預設。") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(installed, id: \.self) { name in
                                HStack(spacing: 8) {
                                    Image(systemName: name == LLMPolicy.requestedName
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(name == LLMPolicy.requestedName
                                                         ? Palette.ink : Palette.dim)
                                    Text(name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Palette.dim)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }

                // The path a phone can actually reach. On a device the importer is
                // the only way in *while the app is open*; with file sharing on,
                // Finder and the Files app write to the same folder with the app
                // closed, which is what makes a 100 MB model installable without a
                // cable and Xcode.
                Card("也可以用 Finder 或「檔案」App 放進去",
                     caption: "我的 iPhone › Hushkey › models（asr/ 與 llm/ 兩個資料夾已經建好了）") {
                    Text(SharedStore.modelsRoot.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
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

    // MARK: download

    /// 從清單下載: the manifest's models, fetched and checked on the phone.
    ///
    /// This is the Mac's model manager, on the phone, and it exists for one reason
    /// the Files route cannot cover: a phone has no way to check a file it received
    /// from Files, and a truncated 1.3 GB model is indistinguishable from a complete
    /// one until the engine refuses it at the first dictation. Here the size and the
    /// SHA-256 come from the same list the Mac uses, and a file that fails is not
    /// left in `models/` to be loaded later.
    private var downloadCard: some View {
        Card("從清單下載",
             caption: "檔案來自 models/manifest.json，下載完先比對大小與 SHA-256，通過才放進 models/。下載期間請讓 App 留在前景：手機不允許一個 1.3 GB 的下載在背景慢慢跑，被暫停就得從頭再來。") {
            VStack(alignment: .leading, spacing: 12) {
                if manifest.isEmpty {
                    Text("這份組建沒有帶清單檔，只能用下面的 Finder／檔案方式放模型。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(groups, id: \.role) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.role)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        ForEach(group.items) { downloadRow($0) }
                    }
                }
            }
        }
        .onChange(of: downloads.installedSomething) { _, _ in
            // A model that just arrived changes what the engine can load, which is
            // the number this screen and the recorder both show.
            ready = SharedStore.hasModels
            if ready { dictation.prewarm() }
        }
    }

    /// ASR first, then the language models: the order of "what is necessary" and
    /// then "what makes it better".
    private var groups: [(role: String, items: [ModelManifest.Item])] {
        [("辨識", manifest.filter { $0.role == "ASR" }),
         ("AI 整理", manifest.filter { $0.role == "LLM" })]
            .filter { !$0.1.isEmpty }
            .map { (role: $0.0, items: $0.1) }
    }

    private func downloadRow(_ item: ModelManifest.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: itemSymbol(item))
                    .font(.system(size: 13))
                    .foregroundStyle(itemInstalled(item) ? Palette.ink : Palette.dim)
                // The path, not the basename: the manifest ships two files called
                // `model.int8.onnx` (SenseVoice at `asr/`, Dolphin at
                // `asr/dolphin/`), and two rows with the same title is a screen
                // where the wrong one gets deleted.
                Text(item.file)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.fetchedOnInstall {
                    Text("預設")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 0)
                Text(ModelManifest.size(item.bytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.dim)
            }
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls(item)
            if let line = statusLine(item) {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(verdicts[item.id] == .ok ? Palette.ink : Palette.seal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func controls(_ item: ModelManifest.Item) -> some View {
        switch downloads.state[item.id] {
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .tint(Palette.seal)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                Button("取消") { downloads.cancel(item.id) }
                    .buttonStyle(QuietButton())
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().tint(Palette.seal)
                Text("比對中…").font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.seal)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("重試") { downloads.download(item) }
                    Button("驗證已放進去的檔案") { verify(item) }
                    Spacer(minLength: 0)
                }
                .buttonStyle(QuietButton())
            }
        case .installed, .none:
            HStack(spacing: 10) {
                Button(itemInstalled(item) ? "重新下載" : "下載") { downloads.download(item) }
                Button(checking == item.id ? "比對中…" : "驗證") { verify(item) }
                    .disabled(checking != nil)
                Spacer(minLength: 0)
            }
            .buttonStyle(QuietButton())
        }
    }

    private func itemInstalled(_ item: ModelManifest.Item) -> Bool {
        FileManager.default.fileExists(atPath: SharedStore.modelsRoot.appendingPathComponent(item.file).path)
    }

    private func itemSymbol(_ item: ModelManifest.Item) -> String {
        itemInstalled(item) ? "checkmark.circle.fill" : "arrow.down.circle"
    }

    /// What 驗證 found, if it has been asked. A verdict is only shown for the entry
    /// it belongs to, so a failed check on one model cannot be read as a statement
    /// about another.
    private func statusLine(_ item: ModelManifest.Item) -> String? {
        guard let verdict = verdicts[item.id] else { return nil }
        switch verdict {
        case .ok:
            return "驗證通過：大小與 SHA-256 都和清單一致。"
        case .missing:
            return "這裡還沒有這個檔案。"
        case .wrongSize(let bytes):
            return "大小不符：磁碟上是 \(ModelManifest.size(bytes))，清單說是 \(ModelManifest.size(item.bytes))。"
        case .wrongHash(let hash):
            return "SHA-256 不符（\(hash.prefix(12))…）：這個檔案不是清單上的那一份。"
        }
    }

    /// Hashes the file on disk against the manifest, off the main thread.
    ///
    /// The explicit button is not a convenience. It is the only way to answer "is
    /// the model I dragged in from Files actually the model?" -- a question the
    /// engine answers much later and less clearly.
    private func verify(_ item: ModelManifest.Item) {
        guard checking == nil else { return }
        checking = item.id
        DispatchQueue.global(qos: .userInitiated).async {
            let verdict = ModelManifest.verify(item, at: SharedStore.modelsRoot)
            DispatchQueue.main.async {
                verdicts[item.id] = verdict
                checking = nil
            }
        }
    }

    // MARK: rows

    /// Both recognisers the core can drive, spelled out: "installed" is a pair of
    /// files, and a screen that said 已安裝 for a folder the engine rejects would
    /// move the failure to the first dictation.
    private var recogniserDetail: String {
        let manager = FileManager.default
        let root = SharedStore.modelsRoot
        var parts: [String] = []
        let sense = ["asr/model.int8.onnx", "asr/model.onnx"].contains {
            manager.fileExists(atPath: root.appendingPathComponent($0).path)
        } && manager.fileExists(atPath: root.appendingPathComponent("asr/tokens.txt").path)
        let dolphin = manager.fileExists(
            atPath: root.appendingPathComponent("asr/dolphin/model.int8.onnx").path
        ) && manager.fileExists(atPath: root.appendingPathComponent("asr/dolphin/tokens.txt").path)
        if sense { parts.append("SenseVoice（asr/）") }
        if dolphin { parts.append("Dolphin（asr/dolphin/）") }
        return parts.isEmpty ? "asr/model.int8.onnx + tokens.txt，或 asr/dolphin/ 一整套" : parts.joined(separator: " · ")
    }

    private var installedLLMs: [String]? {
        let names = LLMPolicy.installed.map(\.name)
        return names.isEmpty ? nil : names
    }

    private func modelRow(title: String, detail: String, ready: Bool, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : (required ? "circle.dashed" : "circle"))
                .font(.system(size: 15))
                .foregroundStyle(ready ? Palette.ink : Palette.dim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(ready ? "已安裝" : (required ? "未安裝" : "未安裝 · 選用"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: import

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

    /// Copies whatever the user picked into the model tree.
    ///
    /// Three shapes arrive here and the UI cannot tell them apart beforehand: a
    /// `models/` folder to merge, an `asr/` or `llm/` folder to drop in place, or
    /// loose files. The extension is the only reliable classifier for the loose
    /// ones, so it decides -- a `.gguf` filed under `asr/` would simply never be
    /// found again.
    private func importModels(from urls: [URL]) {
        busy = true
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
                busy = false
                ready = SharedStore.hasModels
                if ready { dictation.prewarm() }
            }
        }
    }
}
