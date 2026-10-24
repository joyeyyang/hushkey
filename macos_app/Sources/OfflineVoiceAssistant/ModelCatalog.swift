import CryptoKit
import Foundation

/// One row of `models/manifest.json`, as the model manager sees it.
///
/// `download` is the manifest's "fetch this on first launch" flag, not "this may be
/// offered": the manager lists every row and fetches a row when the user picks it.
/// Rows with `download == false` are the optional ones (other LLM sizes, the RAG
/// artifact); `ModelInstaller` only handles the `true` ones.
struct ModelEntry: Codable, Identifiable, Sendable {
    let id: String
    /// "ASR", "LLM" or "RAG".
    let role: String
    /// Path relative to the models root, e.g. "llm/Qwen3.5-2B-Q4_K_M.gguf".
    let file: String
    let bytes: Int64
    /// Lowercase hex digest, or "PENDING" for a row that has no verified artifact yet.
    let sha256: String
    let sourceURL: URL?
    let sourceRepo: String?
    let note: String?
    /// One Chinese line for the model manager. `note` is the long English
    /// rationale written for whoever maintains the manifest; it is shown as a
    /// tooltip, not as body text in a Chinese UI.
    let summaryZH: String?
    let license: String?
    let download: Bool
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, role, file, bytes, sha256, note, license, download
        case sourceURL = "source_url"
        case sourceRepo = "source_repo"
        case summaryZH = "summary_zh"
        case isDefault = "default"
    }

    /// The bare filename, which is what the engine's `OVC_LLM_MODEL` accepts: it
    /// rejects anything containing "/" or ".." and joins it onto `models/llm`.
    var fileName: String { (file as NSString).lastPathComponent }

    /// True when the manifest supplies a digest worth checking. The RAG row ships
    /// "PENDING" until a quantized artifact is verified, and must not be downloaded
    /// before then: the byte count alone would let a truncated or substituted file
    /// through.
    var hasVerifiableDigest: Bool {
        sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit }
    }

    /// True when this row can be fetched and verified at all.
    var isDownloadable: Bool { sourceURL != nil && hasVerifiableDigest }
}

// Decoding lives in an extension so the memberwise initialiser survives; tests and
// the manager build throwaway entries with it.
extension ModelEntry {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        file = try c.decode(String.self, forKey: .file)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        sha256 = try c.decode(String.self, forKey: .sha256)

        // A row without a usable URL is still listable (it just cannot be fetched),
        // so a malformed URL must not fail the whole manifest.
        if let raw = try c.decodeIfPresent(String.self, forKey: .sourceURL),
           let url = URL(string: raw), url.scheme != nil {
            sourceURL = url
        } else {
            sourceURL = nil
        }
        sourceRepo = try c.decodeIfPresent(String.self, forKey: .sourceRepo)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        summaryZH = try c.decodeIfPresent(String.self, forKey: .summaryZH)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        // Match ModelInstaller: a row that omits the flag is downloadable by default.
        download = try c.decodeIfPresent(Bool.self, forKey: .download) ?? true
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

/// Read-only view of what the model manager can offer, plus the cheap on-disk checks
/// it needs. Nothing here downloads or writes.
enum ModelCatalog {
    enum CatalogError: Error, CustomStringConvertible {
        case manifestMissing
        case manifestInvalid(String)
        case unsafePath(String)
        case notSelectable(String)
        case selectedModel(String)

        var description: String {
            switch self {
            case .manifestMissing:
                return "bundled models-manifest.json not found"
            case let .manifestInvalid(what):
                return "manifest invalid: \(what)"
            case let .unsafePath(path):
                return "refusing unsafe model path: \"\(path)\""
            case let .notSelectable(why):
                return "cannot select model: \(why)"
            case let .selectedModel(file):
                return "\(file) is the selected LLM and cannot be deleted"
            }
        }
    }

    private struct Manifest: Decodable {
        let models: [ModelEntry]
    }

    /// The manifest the app ships in `Contents/Resources` (see scripts/build_macos.sh).
    /// `OVC_MODEL_MANIFEST` points the catalog at a file on disk instead, the same
    /// test-hook shape as `OVC_MODELS` and `OVC_SELFTEST_*`.
    static func manifestURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["OVC_MODEL_MANIFEST"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        guard let url = Bundle.main.url(forResource: "models-manifest", withExtension: "json") else {
            throw CatalogError.manifestMissing
        }
        return url
    }

    /// Every row, in manifest order (the order the manager should display).
    static func all() throws -> [ModelEntry] {
        let data: Data
        do {
            data = try Data(contentsOf: try manifestURL())
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.manifestInvalid("unreadable: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data).models
        } catch {
            throw CatalogError.manifestInvalid(String(describing: error))
        }
    }

    static func llms() throws -> [ModelEntry] {
        try all().filter { $0.role.uppercased() == "LLM" }
    }

    /// The row the manifest marks `"default": true` for LLMs, if any.
    static func defaultLLM() throws -> ModelEntry? {
        try llms().first { $0.isDefault }
    }

    /// Looks a row up by the manifest's relative path or by bare filename, because
    /// the engine and UserDefaults both deal in bare filenames.
    static func entry(forFile filename: String) throws -> ModelEntry? {
        let wanted = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let entries = try all()
        if let exact = entries.first(where: { $0.file == wanted }) { return exact }
        let base = (wanted as NSString).lastPathComponent
        return entries.first { $0.fileName == base }
    }

    /// Bytes on disk, or nil when the file is absent (or empty, which is just as
    /// useless as absent). Reports what is actually there, not what was expected.
    static func installedBytes(entry: ModelEntry) -> Int64? {
        let url = modelsDirectory().appendingPathComponent(entry.file)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        return size
    }

    /// Exists and has the manifest's size. The digest is verified once, when the
    /// download lands; re-hashing a 1.3 GB file to paint a menu row would stall the
    /// UI for seconds, so this stays a stat() call.
    static func isInstalled(entry: ModelEntry) -> Bool {
        installedBytes(entry: entry) == entry.bytes
    }

    /// Where the models live. Mirrors the app's own resolution so the manager and the
    /// engine read the same tree: `OVC_MODELS`, then `OVC_DATA_DIR`, then Application
    /// Support. Creates nothing; callers make subdirectories as needed.
    static func modelsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["OVC_MODELS"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        let base: URL
        if let dir = env["OVC_DATA_DIR"], !dir.isEmpty {
            base = URL(fileURLWithPath: dir)
        } else if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) {
            base = support.appendingPathComponent("OfflineVoiceAssistant", isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/OfflineVoiceAssistant",
                                        isDirectory: true)
        }
        return base.appendingPathComponent("models", isDirectory: true)
    }

    /// A manifest path must stay inside the models directory: no absolute path, no
    /// "~", no empty component (which would collapse two slashes), no "." or "..".
    /// Backslashes are refused too: no legitimate model file needs one, and on a
    /// manifest copied from Windows it would silently become part of a filename.
    static func relativePathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        guard !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts where part.isEmpty || part == "." || part == ".." {
            return false
        }
        return true
    }

    /// Streams the file in 1 MiB chunks so a 1.3 GB model is never resident.
    /// Same shape as ModelInstaller.sha256; kept here so the manager can verify a
    /// download without depending on the installer (which must stay untouched).
    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The user's LLM choice: persisted under `settings.llmModel` and handed to the engine
/// as `OVC_LLM_MODEL`. Only the filename travels, because the engine validates that and
/// joins it onto `<models>/llm` itself (see `llm_model_path` in core_engine/src/state.rs).
enum LLMSelection {
    static let defaultsKey = "settings.llmModel"
    static let engineVariable = "OVC_LLM_MODEL"
    /// Last-resort name. An install that predates Qwen3.5 only has this file, and the
    /// engine falls back to it too, so naming it is always truthful.
    static let legacyFileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"

    /// The defaults domain; `OVC_DEFAULTS_SUITE` isolates tests from the app's domain.
    private static var defaults: UserDefaults {
        let env = ProcessInfo.processInfo.environment
        if let suite = env["OVC_DEFAULTS_SUITE"], !suite.isEmpty,
           let isolated = UserDefaults(suiteName: suite) {
            return isolated
        }
        return .standard
    }

    /// Resolution order, mirroring the engine's own:
    /// 1. the stored name, when it still matches a manifest LLM (honoured even if the
    ///    file is not on disk yet, so a selection made mid-download is not discarded);
    /// 2. the manifest's default LLM, but only when that file is installed — otherwise
    ///    the default would point at a model this machine does not have;
    /// 3. the legacy Qwen2.5 name.
    static var currentFileName: String {
        if let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty,
           let entry = try? ModelCatalog.entry(forFile: stored),
           entry.role.uppercased() == "LLM" {
            return entry.fileName
        }
        if let entry = try? ModelCatalog.defaultLLM(),
           ModelCatalog.isInstalled(entry: entry) {
            return entry.fileName
        }
        return legacyFileName
    }

    /// True when `entry` is the model the engine would load right now.
    static func isSelected(_ entry: ModelEntry) -> Bool {
        entry.role.uppercased() == "LLM" && entry.fileName == currentFileName
    }

    /// Persists the choice. Refuses anything the engine cannot load or the manager
    /// could never verify: a non-LLM row, an unsafe path, or a row whose digest is
    /// still "PENDING" (the RAG artifact).
    static func select(_ entry: ModelEntry) throws {
        guard entry.role.uppercased() == "LLM" else {
            throw ModelCatalog.CatalogError.notSelectable(
                "\(entry.id) has role \(entry.role), not LLM")
        }
        guard ModelCatalog.relativePathIsSafe(entry.file) else {
            throw ModelCatalog.CatalogError.unsafePath(entry.file)
        }
        guard entry.isDownloadable else {
            throw ModelCatalog.CatalogError.notSelectable(
                "\(entry.id) has no verifiable digest (\(entry.sha256)) or no source URL")
        }
        defaults.set(entry.fileName, forKey: defaultsKey)
    }

    /// Environment to merge when spawning the LLM worker.
    static var environment: [String: String] {
        [engineVariable: currentFileName]
    }

    /// The core spawns `ovc-llm-worker` with `Command::new` (state.rs:797), so the
    /// worker inherits *this* process's environment — passing a dictionary to a spawn
    /// call here would reach nothing. Call this once at startup, before the first
    /// refine pass, and again whenever `select` changes the choice.
    @discardableResult
    static func applyToProcessEnvironment() -> Int32 {
        setenv(engineVariable, currentFileName, 1)
    }
}
