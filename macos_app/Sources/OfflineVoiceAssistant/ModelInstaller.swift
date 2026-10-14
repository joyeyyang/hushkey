import CryptoKit
import Foundation

/// First-launch model installer. Reads the manifest bundled in Resources, downloads each
/// entry with download == true, verifies byte size and SHA-256, and only then moves the
/// file into place, so a partial file never appears under its final name.
/// Limitation: no resume. An interrupted download restarts from zero
/// (scripts/download_models.sh supports resume for developers).
enum ModelInstaller {
    struct Item {
        let id: String
        let url: URL
        let file: String
        let bytes: Int64
        let sha256: String
    }

    enum InstallError: Error, CustomStringConvertible {
        case manifestMissing
        case manifestInvalid(String)
        case http(Int, String)
        case size(String, Int64, Int64)
        case hash(String)

        var description: String {
            switch self {
            case .manifestMissing:
                return "bundled models-manifest.json not found"
            case let .manifestInvalid(what):
                return "manifest invalid: \(what)"
            case let .http(code, id):
                return "download of \(id) failed with HTTP \(code)"
            case let .size(id, got, want):
                return "\(id) is \(got) bytes, expected \(want)"
            case let .hash(id):
                return "\(id) failed SHA-256 verification"
            }
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func items() throws -> [Item] {
        guard let url = Bundle.main.url(forResource: "models-manifest", withExtension: "json") else {
            throw InstallError.manifestMissing
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw InstallError.manifestInvalid("missing models array")
        }
        return try models.compactMap { m in
            guard (m["download"] as? Bool) ?? true else { return nil }
            let id = m["id"] as? String ?? "?"
            guard let src = m["source_url"] as? String, let u = URL(string: src),
                  let file = m["file"] as? String,
                  let bytes = (m["bytes"] as? NSNumber)?.int64Value,
                  let sha = m["sha256"] as? String else {
                throw InstallError.manifestInvalid("entry \(id) incomplete")
            }
            guard sha != "PENDING" else { throw InstallError.manifestInvalid("entry \(id) has no sha256") }
            return Item(id: id, url: u, file: file, bytes: bytes, sha256: sha)
        }
    }

    /// Ensures every downloadable model exists under `root` with the manifest's size and hash.
    /// `progress` receives human-readable status and may be called from a background thread.
    static func ensureInstalled(root: URL, progress: @escaping (String) -> Void) throws {
        let all = try items()
        for (i, item) in all.enumerated() {
            let dest = root.appendingPathComponent(item.file)
            if try isValid(dest, item) {
                log("model cached: \(item.id)")
                continue
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let label = "Downloading model \(i + 1)/\(all.count)"
            try DownloadTask(item: item, dest: dest) { fraction in
                progress("\(label) \(Int(fraction * 100))%")
            }.run()
            log("model ok: \(item.id)")
        }
    }

    static func isValid(_ url: URL, _ item: Item) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == item.bytes else { return false }
        return try sha256(of: url) == item.sha256
    }

    /// Streams the file in 1 MiB chunks so large models are never fully resident.
    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One download with its own session. `run()` blocks the calling (background) thread.
    final class DownloadTask: NSObject, URLSessionDownloadDelegate {
        private let item: Item
        private let dest: URL
        private let onProgress: (Double) -> Void
        private let done = DispatchSemaphore(value: 0)
        private var failure: Error?

        init(item: Item, dest: URL, onProgress: @escaping (Double) -> Void) {
            self.item = item
            self.dest = dest
            self.onProgress = onProgress
        }

        func run() throws {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            session.downloadTask(with: item.url).resume()
            done.wait()
            if let failure { throw failure }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten written: Int64,
                        totalBytesExpectedToWrite _: Int64) {
            onProgress(min(1, Double(written) / Double(item.bytes)))
        }

        /// The temp file is deleted when this returns, so verify and move here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw InstallError.http(http.statusCode, item.id)
                }
                let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                guard size == item.bytes else { throw InstallError.size(item.id, size, item.bytes) }
                guard try ModelInstaller.sha256(of: location) == item.sha256 else {
                    throw InstallError.hash(item.id)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, failure == nil { failure = error }
            done.signal()
        }
    }
}
