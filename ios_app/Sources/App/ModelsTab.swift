import SwiftUI
import UniformTypeIdentifiers

/// The 模型 tab: what is installed, how to put more there, and how to undo a
/// downgrade.
///
/// The Mac's model manager downloads and verifies from a manifest; a phone cannot
/// afford to. iOS gets the files from Finder/Files (file sharing is on) or from the
/// document picker, so this screen's job is to say *what is here*, *what the engine
/// will actually load*, and *what happened to the model choice* — the three things
/// that turn "the AI stopped working" into an answer.
struct ModelsTab: View {
    @Binding var ready: Bool
    @ObservedObject private var dictation = DictationController.shared
    @State private var importing = false
    @State private var busy = false

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
