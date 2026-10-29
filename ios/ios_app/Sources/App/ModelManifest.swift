import CryptoKit
import Foundation

/// The model manifest, and what it says about a file on this device.
///
/// `models/manifest.json` is the same file the Mac's build copies into
/// `Contents/Resources/models-manifest.json` — one list of model files with their
/// sizes and SHA-256s, shipped to both platforms instead of kept twice. A second
/// copy is how one of them ends up stale, and a stale hash is worse than no hash:
/// it reports a good download as corrupt, and the user's next move is to delete a
/// working 1.3 GB file.
///
/// This is the half of the model manager that has no opinion: parse, hash, say
/// whether the file on disk is the file the manifest describes. `ModelDownloads`
/// is the half that talks to the network.
enum ModelManifest {

    struct Item: Identifiable, Equatable {
        let id: String
        /// "ASR" or "LLM". The screen groups by this.
        let role: String
        /// Path under the model root, e.g. `llm/Qwen3.5-2B-Q4_K_M.gguf`.
        let file: String
        let url: URL
        let bytes: Int64
        let sha256: String
        /// The manifest's own one-line Chinese summary, shown under the name.
        let summary: String
        /// Marked `download: true` — what the Mac fetches on first launch.
        let fetchedOnInstall: Bool

        var name: String { (file as NSString).lastPathComponent }
    }

    /// Either name the manifest ships under: the Mac's build renames it on the way
    /// into the bundle (`models-manifest.json`), this app copies it verbatim
    /// (`manifest.json`), and reading both is cheaper than caring which.
    private static var manifestURL: URL? {
        Bundle.main.url(forResource: "models-manifest", withExtension: "json")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json")
    }

    /// Everything the model screen can offer: the recognisers and the language
    /// models, in manifest order.
    ///
    /// `download: false` is not "unavailable". On the Mac it means "not fetched at
    /// first launch, offered by the manager instead" — which is exactly what this
    /// screen is, and it is why the Dolphin pair and the other three language model
    /// sizes appear here rather than being hidden.
    ///
    /// An entry with no hash is dropped rather than listed with a download button
    /// that cannot be checked; `PENDING` is the manifest's own word for that.
    static func items() -> [Item] {
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]]
        else {
            // Not fatal: the screen then says nothing can be downloaded and the
            // Files-app route still works. Logged because a manifest that is
            // missing from the bundle is a build mistake, not a user's.
            Diagnostics.log.error("model manifest not readable from the bundle")
            return []
        }
        return models.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let raw = entry["source_url"] as? String, let url = URL(string: raw),
                  let file = entry["file"] as? String,
                  let bytes = (entry["bytes"] as? NSNumber)?.int64Value,
                  let sha = entry["sha256"] as? String,
                  sha != "PENDING", sha.count == 64
            else { return nil }
            return Item(
                id: id,
                role: entry["role"] as? String ?? "",
                file: file,
                url: url,
                bytes: bytes,
                sha256: sha.lowercased(),
                summary: entry["summary_zh"] as? String ?? "",
                fetchedOnInstall: (entry["download"] as? Bool) ?? true
            )
        }
    }

    /// The items, by id, parsed once. The download delegate looks entries up from a
    /// task's id, and re-reading and re-parsing the bundle on every progress
    /// callback of a 1.3 GB download is worth not doing.
    private static let byID: [String: Item] = {
        Dictionary(uniqueKeysWithValues: items().map { ($0.id, $0) })
    }()

    static func item(id: String) -> Item? { byID[id] }

    // MARK: verification

    enum Verdict: Equatable {
        case missing
        case ok
        /// The right file with the wrong number of bytes: a download that stopped.
        case wrongSize(Int64)
        /// The right size with the wrong contents: the case the hash exists for.
        case wrongHash(String)
    }

    static func verify(_ item: Item, at root: URL) -> Verdict {
        let url = root.appendingPathComponent(item.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        guard size?.int64Value == item.bytes else { return .wrongSize(size?.int64Value ?? -1) }
        guard let hash = try? sha256(of: url) else { return .wrongHash("讀不到") }
        return hash == item.sha256 ? .ok : .wrongHash(hash)
    }

    /// Streams the file in 1 MiB chunks, so hashing a 1.3 GB model never makes it
    /// resident. The Mac's `ModelInstaller.sha256` is the same loop.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "228 MB", "1.19 GB". A model screen without sizes is a screen nobody can
    /// plan a download from.
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
