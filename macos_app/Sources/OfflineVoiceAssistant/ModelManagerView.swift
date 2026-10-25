import AppKit

/// The state line's colour: a plain row, a finished row, or a running transfer.
private enum ModelRowTone { case neutral, ok, busy }

/// One row's painted state, derived from the manifest, the disk and the single
/// in-flight download. The row view keeps none of this, so a progress tick
/// repaints one row without rebuilding the list.
private struct ModelRowModel {
    var name: String
    var detail: String
    /// Long-form text for the tooltip (the manifest's English note).
    var tooltip: String?
    var state = ""
    var tone: ModelRowTone = .neutral
    var download = false
    var downloadEnabled = true
    var cancel = false
    var delete = false
    var use = false
    var message: String?
}

/// The 模型 tab: every manifest row grouped by role, with the one download slot
/// the downloader allows and the LLM switch the engine honours at runtime.
///
/// Two asymmetries shape it. ASR has no runtime switch — the engine picks
/// `asr/dolphin/` then `asr/` at startup — so the tab says so instead of
/// offering a dead button. And a download is one task per `ModelDownloader`, so
/// a live transfer owns the tab and every other 下載 is disabled.
final class ModelManagerView: NSView {
    /// Fired after a successful LLM switch, so the controller can push the new
    /// filename into the engine's environment.
    var onModelChanged: (() -> Void)?

    private struct Section { let role, title: String; let hint: String? }

    private static let sections = [
        Section(role: "ASR", title: "語音辨識（ASR）",
                hint: "ASR 沒有執行時切換：引擎啟動時優先用 asr/dolphin/，找不到才用 asr/。"
                    + "新下載的 ASR 要重新啟動 App 才會載入；目前使用中的那份不提供刪除。"),
        Section(role: "LLM", title: "語言模型（LLM）",
                hint: "按「使用」會記住檔名並設成 OVC_LLM_MODEL，下一次整理逐字稿就換成這個模型。"),
        Section(role: "RAG", title: "檢索模型（向量）",
                hint: "關鍵字檢索與口頭指令篩選用的向量模型。不是選項，裝好就會用；"
                    + "關掉設定裡的「檢索輔助」即可停用，沒有它也能正常聽寫。"),
    ]

    private var theme: Theme
    private var entries: [ModelEntry] = []
    private var manifestError: String?

    // Download state. A non-nil `downloader` is the tab's one-at-a-time lock.
    private var downloader: ModelDownloader?
    private var downloadingID: String?
    private var progress: ModelDownloader.Progress?
    /// The digest pass runs after the downloader reports success; until it
    /// returns, the row keeps saying 驗證中 because the file is not trusted yet.
    private var verifyingID: String?
    private var failures: [String: String] = [:]

    private var rowsByID: [String: RowView] = [:]
    private var sectionLabels: [NSTextField] = []
    private var hintLabels: [NSTextField] = []

    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let contentStack = NSStackView()

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        buildUI()
        applyTheme(theme)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        headerLabel.font = theme.fontHeading
        headerLabel.textColor = theme.textPrimary
        for label in sectionLabels {
            label.font = theme.fontHeading
            label.textColor = theme.textPrimary
        }
        for label in hintLabels {
            label.font = theme.fontSmall
            label.textColor = theme.textSecondary
        }
        for row in rowsByID.values { row.applyTheme(theme) }
    }

    /// Re-reads the manifest and the disk. Cheap by design: `isInstalled` is a
    /// stat() against the manifest's byte count, never a re-hash.
    func reload() {
        do {
            entries = try ModelCatalog.all()
            manifestError = nil
        } catch {
            entries = []
            manifestError = "讀不到模型清單：\(error)"
            ModelInstaller.log("model manager: manifest unreadable: \(error)")
        }
        rebuildRows()
        refreshHeader()
    }

    // MARK: - Layout

    private func buildUI() {
        headerLabel.maximumNumberOfLines = 3
        headerLabel.stringValue = "正在讀取模型清單…"
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Metrics.space3
        contentStack.edgeInsets = NSEdgeInsets(top: Metrics.space4, left: Metrics.space4,
                                              bottom: Metrics.space4, right: Metrics.space4)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(contentStack)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space4),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space4),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space4),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: Metrics.space3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            // Tall content drives the document height; the stack is never
            // stretched to fill a short document.
            document.heightAnchor.constraint(greaterThanOrEqualTo: contentStack.heightAnchor),
        ])
    }

    private func addFullWidth(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor,
                                    constant: -Metrics.space6).isActive = true
    }

    private func rebuildRows() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowsByID = [:]
        sectionLabels = []
        hintLabels = []

        if let error = manifestError {
            let label = NSTextField(wrappingLabelWithString: error)
            label.font = theme.fontSmall
            label.textColor = theme.danger
            addFullWidth(label)
            return
        }

        for section in Self.sections {
            let matching = entries.filter { $0.role.uppercased() == section.role }
            if !matching.isEmpty {
                addSection(title: section.title, hint: section.hint, entries: matching)
            }
        }

        // Any role the sections above do not name (today: the RAG artifact). Its
        // digest is still "PENDING", so it lists without a download button.
        let known = Set(Self.sections.map(\.role))
        let others = entries.filter { !known.contains($0.role.uppercased()) }
        if !others.isEmpty {
            addSection(title: "其他（\(others[0].role)）", hint: nil, entries: others)
        }
    }

    private func addSection(title: String, hint: String?, entries listed: [ModelEntry]) {
        let label = NSTextField(labelWithString: title)
        label.font = theme.fontHeading
        label.textColor = theme.textPrimary
        sectionLabels.append(label)
        addFullWidth(label)

        if let hint {
            let hintLabel = NSTextField(wrappingLabelWithString: hint)
            hintLabel.font = theme.fontSmall
            hintLabel.textColor = theme.textSecondary
            hintLabels.append(hintLabel)
            addFullWidth(hintLabel)
        }

        for entry in listed {
            let row = RowView()
            row.onDownload = { [weak self] in self?.startDownload(entry) }
            row.onCancel = { [weak self] in self?.downloader?.cancel() }
            row.onDelete = { [weak self] in self?.confirmDelete(entry) }
            row.onUse = { [weak self] in self?.use(entry) }
            addFullWidth(row)
            rowsByID[entry.id] = row
            row.render(presentation(for: entry), theme: theme)
        }
    }

    // MARK: - Header

    private func refreshHeader() {
        guard manifestError == nil else {
            headerLabel.stringValue = "模型清單讀取失敗，詳情如下。"
            return
        }
        let asr = loadedASREntry.map {
            "\(Self.displayName($0))（\(Self.sizeLabel($0.bytes)) 權重）"
        } ?? "找不到 ASR 權重"

        let llm: String
        if let entry = entries.first(where: { LLMSelection.isSelected($0) }) {
            llm = ModelCatalog.isInstalled(entry: entry)
                ? "\(Self.displayName(entry))（\(Self.sizeLabel(entry.bytes)) 權重）"
                : "\(Self.displayName(entry))（尚未下載，執行時會回退）"
        } else {
            llm = "\(LLMSelection.currentFileName)（不在清單裡）"
        }
        let peak = Self.peakResidentBytes().map(Self.sizeLabel) ?? "無法讀取"
        headerLabel.stringValue = "目前載入：\(asr)；LLM：\(llm)；本程式峰值記憶體 \(peak)"
    }

    /// The ASR weights the engine's own resolution lands on, in the loader's
    /// order: `asr/dolphin/` first, then `asr/`.
    private var loadedASREntry: ModelEntry? {
        let asr = entries.filter { $0.role.uppercased() == "ASR" }
        func pick(_ prefix: String) -> ModelEntry? {
            asr.first { $0.file.hasPrefix(prefix) && $0.file.hasSuffix(".onnx")
                && ModelCatalog.isInstalled(entry: $0) }
                ?? asr.first { $0.file.hasPrefix(prefix) && ModelCatalog.isInstalled(entry: $0) }
        }
        return pick("asr/dolphin/") ?? pick("asr/")
    }

    // MARK: - Row state

    private func presentation(for entry: ModelEntry) -> ModelRowModel {
        let isLLM = entry.role.uppercased() == "LLM"
        var model = ModelRowModel(name: Self.displayName(entry), detail: Self.detailText(entry))
        model.tooltip = entry.note
        model.message = failures[entry.id]

        if downloadingID == entry.id {
            if let progress {
                let percent = Int((progress.fraction * 100).rounded())
                model.state = "下載中 \(percent)%・\(Self.rateLabel(progress.bytesPerSecond))"
                    + "・剩 \(Self.etaLabel(progress.eta))"
            } else {
                model.state = "下載中…"
            }
            model.tone = .busy
            model.cancel = true
            return model
        }
        if verifyingID == entry.id {
            model.state = "驗證中，重新計算 SHA-256…"
            model.tone = .busy
            return model
        }
        if ModelCatalog.isInstalled(entry: entry) {
            let selected = LLMSelection.isSelected(entry)
            let inUseASR = !isLLM && loadedASREntry?.id == entry.id
            model.tone = .ok
            model.state = selected || inUseASR ? "已安裝・使用中" : "已安裝"
            model.use = isLLM && !selected
            // Neither the engine's LLM nor the ASR weights it opens can go: the
            // next launch would have nothing to load.
            model.delete = !selected && !inUseASR
            return model
        }

        if let onDisk = ModelCatalog.installedBytes(entry: entry) {
            model.state = "未安裝（磁碟上有 \(Self.sizeLabel(onDisk)) 的檔案，可能下載中斷）"
        } else {
            model.state = "未安裝"
        }
        if entry.isDownloadable {
            model.download = true
            model.downloadEnabled = downloader == nil
        } else {
            model.state += "・manifest 沒有可驗證的 sha256，暫不提供下載"
        }
        return model
    }

    private func refreshRow(_ entry: ModelEntry) {
        rowsByID[entry.id]?.render(presentation(for: entry), theme: theme)
    }

    private func refreshAllRows() {
        for entry in entries { refreshRow(entry) }
        refreshHeader()
    }

    // MARK: - Downloading

    private func startDownload(_ entry: ModelEntry) {
        guard downloader == nil else { return }
        guard entry.isDownloadable else {
            failures[entry.id] = "manifest 的 sha256 不是可驗證的摘要（\(entry.sha256)），"
                + "下載了也無法確認完整。"
            refreshRow(entry)
            return
        }
        failures[entry.id] = nil
        let downloader = ModelDownloader(entry: entry,
                                        destinationDirectory: ModelCatalog.modelsDirectory())
        self.downloader = downloader
        downloadingID = entry.id
        progress = nil
        refreshRow(entry)

        // Both callbacks arrive on the downloader's private queue; AppKit is only
        // touched after hopping back to the main one.
        downloader.start(progress: { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.downloadingID == entry.id else { return }
                self.progress = progress
                self.refreshRow(entry)
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async { self?.finishDownload(entry, result) }
        })
    }

    private func finishDownload(_ entry: ModelEntry, _ result: Result<URL, Error>) {
        downloader = nil
        downloadingID = nil
        progress = nil
        switch result {
        case let .failure(error):
            if let download = error as? ModelDownloader.DownloadError, case .cancelled = download {
                ModelInstaller.log("model download cancelled: \(entry.id)")
            } else {
                ModelInstaller.log("model download failed: \(entry.id): \(error)")
            }
            failures[entry.id] = Self.describe(error, entry: entry)
            refreshRow(entry)
            refreshHeader()

        case let .success(url):
            // The downloader verified size and digest before the move; this pass
            // proves the bytes that survived the move are the manifest's bytes.
            verifyingID = entry.id
            refreshRow(entry)
            DispatchQueue.global(qos: .utility).async {
                let problem = Self.verify(entry: entry, url: url)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.verifyingID = nil
                    if let problem {
                        try? FileManager.default.removeItem(at: url)
                        self.failures[entry.id] = problem
                        ModelInstaller.log("model verify failed: \(entry.id): \(problem)")
                    } else {
                        ModelInstaller.log("model ok: \(entry.id)")
                    }
                    self.refreshAllRows()
                }
            }
        }
    }

    /// Nil means the file is exactly what the manifest describes. Any other
    /// answer names the check that failed: "下載失敗" alone would send the user to
    /// the network when the real cause is the disk.
    private static func verify(entry: ModelEntry, url: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let got = (attrs?[.size] as? NSNumber)?.int64Value else {
            return "下載結束後找不到檔案（\(entry.file)），請再試一次。"
        }
        guard got == entry.bytes else {
            return "檔案大小不符：收到 \(sizeLabel(got))，manifest 記載 \(sizeLabel(entry.bytes))。"
                + "已刪除這個檔案，請重新下載。"
        }
        guard entry.hasVerifiableDigest else {
            return "manifest 沒有可驗證的 sha256，無法確認檔案完整，已刪除。"
        }
        guard let digest = try? ModelCatalog.sha256(of: url) else {
            return "無法讀取檔案計算 SHA-256，已刪除，請重新下載。"
        }
        guard digest == entry.sha256.lowercased() else {
            return "SHA-256 不符：內容與 manifest 不一致，已刪除。可能被中途替換，請重新下載。"
        }
        return nil
    }

    private static func describe(_ error: Error, entry: ModelEntry) -> String {
        if let download = error as? ModelDownloader.DownloadError {
            switch download {
            case let .http(code):
                return "伺服器回 HTTP \(code)。404 代表 manifest 的來源已失效；"
                    + "403 可能是該站要先接受授權；其他代碼請稍後再試。"
            case let .sizeMismatch(expected, got):
                return "大小不符：收到 \(sizeLabel(got))，應為 \(sizeLabel(expected))。"
            case .hashMismatch:
                return "SHA-256 不符：下載內容與 manifest 不一致，已丟棄這個檔案。"
            case .cancelled:
                return "已取消下載。"
            case .diskFull:
                return "磁碟空間不足：放不下 \(sizeLabel(entry.bytes))，請先清出空間再下載。"
            case let .invalidRequest(why):
                return "無法下載：\(why)"
            case let .insecureRedirect(url):
                return "伺服器要求轉到非 HTTPS 位址（\(url)），已拒絕跟隨。"
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "網路錯誤（\(ns.code)）：\(ns.localizedDescription)"
        }
        return "下載失敗：\(error.localizedDescription)"
    }

    // MARK: - Selecting / deleting

    private func use(_ entry: ModelEntry) {
        guard entry.role.uppercased() == "LLM" else { return }
        do {
            try LLMSelection.select(entry)
            // The core spawns its worker with the inherited environment, so the
            // change has to land in this process, not in a spawn argument.
            LLMSelection.applyToProcessEnvironment()
            failures[entry.id] = nil
            ModelInstaller.log("llm selected: \(entry.fileName)")
            onModelChanged?()
        } catch {
            failures[entry.id] = "無法切換：\(error)"
            ModelInstaller.log("llm select failed: \(entry.id): \(error)")
        }
        refreshAllRows()
    }

    private func confirmDelete(_ entry: ModelEntry) {
        guard !LLMSelection.isSelected(entry) else {
            failures[entry.id] = "這是目前使用的 LLM。請先切換到別的模型，再刪除它。"
            refreshRow(entry)
            return
        }
        let alert = NSAlert()
        alert.messageText = "刪除 \(Self.displayName(entry))？"
        alert.informativeText = "會從磁碟移除 \(Self.sizeLabel(entry.bytes))，"
            + "下次要用時得重新下載，不能復原。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ModelDownloader.delete(entry)
            failures[entry.id] = nil
            ModelInstaller.log("model deleted: \(entry.id)")
        } catch {
            failures[entry.id] = "刪除失敗：\(error)"
        }
        refreshAllRows()
    }

    // MARK: - Naming and units

    /// The manifest id, made readable: `asr-dolphin-base-int8` becomes
    /// "Dolphin base int8", `llm-qwen3.5-2b-q4-k-m` becomes "Qwen3.5 2B Q4_K_M".
    /// The filename cannot carry this — two rows are both `model.int8.onnx`.
    private static func displayName(_ entry: ModelEntry) -> String {
        var parts = entry.id.lowercased().components(separatedBy: "-")
        if parts.first == entry.role.lowercased() { parts.removeFirst() }
        // Only the brands this manifest actually spells in lowercase.
        let brands = ["sensevoice": "SenseVoice", "whisper": "Whisper"]

        var words: [String] = []
        while let token = parts.first {
            parts.removeFirst()
            if token.isEmpty || token == "gguf" || token == "onnx" { continue }
            // "q4" plus the precision letters after it: q4-k-m -> Q4_K_M.
            if token.count > 1, token.first == "q", token.dropFirst().allSatisfy(\.isNumber) {
                var quant = [token.uppercased()]
                while let next = parts.first, ["k", "m", "s"].contains(next) {
                    quant.append(next.uppercased())
                    parts.removeFirst()
                }
                words.append(quant.joined(separator: "_"))
            } else if let last = token.last, "bm".contains(last),
                      token.first?.isNumber == true,
                      token.dropLast().allSatisfy({ $0.isNumber || $0 == "." }) {
                // Parameter count or quantized size: 2b -> 2B, 300m -> 300M.
                words.append(String(token.dropLast()) + String(last).uppercased())
            } else if let brand = brands[token] {
                words.append(brand)
            } else if words.isEmpty {
                words.append(token.prefix(1).uppercased() + String(token.dropFirst()))
            } else {
                words.append(token)
            }
        }
        return words.isEmpty ? entry.fileName : words.joined(separator: " ")
    }

    private static func detailText(_ entry: ModelEntry) -> String {
        let size = sizeLabel(entry.bytes)
        // The manifest's `note` is an English paragraph written for whoever
        // maintains it; `summary_zh` is the one line a user needs.
        if let summary = entry.summaryZH, !summary.isEmpty {
            return "\(size)・\(summary)"
        }
        guard let note = entry.note, !note.isEmpty else { return size }
        return "\(size)・\(note)"
    }

    /// Decimal units, like the manifest's own notes: 99 MB means 99,000,000 bytes.
    private static func sizeLabel(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1e6) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1e3) }
        return "\(bytes) bytes"
    }

    private static func rateLabel(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond >= 0.5 else { return "等速率" }
        return String(format: "%.1f MB/s", bytesPerSecond / 1e6)
    }

    private static func etaLabel(_ eta: TimeInterval?) -> String {
        guard let eta, eta.isFinite, eta >= 0 else { return "估算中" }
        if eta < 60 { return "\(Int(eta.rounded())) 秒" }
        return String(format: "%d 分 %02d 秒", Int(eta) / 60, Int(eta) % 60)
    }

    /// Peak RSS since launch, which includes the resident model — that is the
    /// number worth showing. `ru_maxrss` is bytes on Darwin.
    private static func peakResidentBytes() -> Int64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Int64(usage.ru_maxrss)
    }

    // MARK: - One row

    /// A card for one manifest row. It paints a `ModelRowModel` and forwards taps;
    /// all state lives in `ModelManagerView`, so neither a theme change nor a
    /// progress tick has to rebuild it.
    private final class RowView: NSView {
        var onDownload: (() -> Void)?
        var onCancel: (() -> Void)?
        var onDelete: (() -> Void)?
        var onUse: (() -> Void)?

        private let nameLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let stateLabel = NSTextField(wrappingLabelWithString: "")
        private let messageLabel = NSTextField(wrappingLabelWithString: "")
        private let downloadButton = NSButton(title: "下載", target: nil, action: nil)
        private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        private let deleteButton = NSButton(title: "刪除", target: nil, action: nil)
        private let useButton = NSButton(title: "使用", target: nil, action: nil)
        private let buttonRow = NSStackView()
        private var tone: ModelRowTone = .neutral

        init() {
            super.init(frame: .zero)
            wantsLayer = true

            nameLabel.lineBreakMode = .byTruncatingTail
            detailLabel.lineBreakMode = .byTruncatingTail
            stateLabel.maximumNumberOfLines = 2
            messageLabel.maximumNumberOfLines = 2

            for button in [downloadButton, cancelButton, deleteButton, useButton] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.target = self
            }
            downloadButton.action = #selector(didTapDownload)
            cancelButton.action = #selector(didTapCancel)
            deleteButton.action = #selector(didTapDelete)
            useButton.action = #selector(didTapUse)
            buttonRow.setViews([downloadButton, cancelButton, deleteButton, useButton], in: .leading)
            buttonRow.orientation = .horizontal
            buttonRow.spacing = Metrics.space2
            buttonRow.setContentHuggingPriority(.required, for: .horizontal)

            let text = NSStackView(views: [nameLabel, detailLabel, stateLabel, messageLabel])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = Metrics.space1
            // The text column absorbs the spare width, so every row's buttons
            // line up on the right instead of sitting next to a short sentence.
            text.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            text.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            // An explicit spacer rather than hugging priorities: NSStackView
            // hands spare width to the spacer, which is what pins the buttons to
            // the right edge on every row, however long the sentence is.
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            let row = NSStackView(views: [text, spacer, buttonRow])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = Metrics.space3
            row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                // The wrapping labels only wrap against a known width, and the
                // stack alone would let each take its single-line width.
                nameLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
                detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
                stateLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
                messageLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func render(_ model: ModelRowModel, theme: Theme) {
            tone = model.tone
            nameLabel.stringValue = model.name
            detailLabel.stringValue = model.detail
            // The long rationale stays reachable, just not in the body text.
            detailLabel.toolTip = model.tooltip ?? model.detail
            stateLabel.stringValue = model.state
            stateLabel.isHidden = model.state.isEmpty
            messageLabel.stringValue = model.message ?? ""
            messageLabel.isHidden = (model.message ?? "").isEmpty
            downloadButton.isHidden = !model.download
            downloadButton.isEnabled = model.downloadEnabled
            cancelButton.isHidden = !model.cancel
            deleteButton.isHidden = !model.delete
            useButton.isHidden = !model.use
            buttonRow.isHidden = !(model.download || model.cancel || model.delete || model.use)
            applyTheme(theme)
        }

        func applyTheme(_ theme: Theme) {
            layer?.backgroundColor = theme.surface.cgColor
            layer?.borderColor = theme.border.cgColor
            layer?.borderWidth = 1
            layer?.cornerRadius = Metrics.radiusSmall
            nameLabel.font = theme.fontHeading
            nameLabel.textColor = theme.textPrimary
            detailLabel.font = theme.fontSmall
            detailLabel.textColor = theme.textSecondary
            stateLabel.font = theme.fontSmall
            stateLabel.textColor = Self.colour(for: tone, in: theme)
            messageLabel.font = theme.fontSmall
            messageLabel.textColor = theme.danger
        }

        private static func colour(for tone: ModelRowTone, in theme: Theme) -> NSColor {
            switch tone {
            case .neutral: return theme.textSecondary
            case .ok: return theme.success
            case .busy: return theme.accent
            }
        }

        @objc private func didTapDownload() { onDownload?() }
        @objc private func didTapCancel() { onCancel?() }
        @objc private func didTapDelete() { onDelete?() }
        @objc private func didTapUse() { onUse?() }
    }
}
