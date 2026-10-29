import Foundation

/// Downloading a model from the manifest, checking it, and putting it in place.
///
/// Those three happen in that order and none of them may be skipped. The phone's
/// other way in is the Files app, where a copy that stopped at 800 MB looks exactly
/// like a complete 1.3 GB file until the engine refuses it — and the engine's
/// refusal arrives at the first dictation, as a sentence about the model rather
/// than about the copy. Checking here is what makes the difference between "the
/// download failed, try again" and a support conversation.
///
/// The Mac does the same thing in `ModelInstaller`; this is the iOS spelling of it,
/// with one deliberate difference. A phone is not allowed to run for the ten
/// minutes a 1.3 GB download takes, so the session is a foreground one and the
/// screen says so: a background `URLSession` would keep the transfer alive across a
/// suspension, but it also has to survive the app being relaunched to hand the file
/// over, which is a second mechanism (and a second set of states) for a case a
/// message can prevent.
final class ModelDownloads: NSObject, ObservableObject {
    static let shared = ModelDownloads()

    enum State: Equatable {
        case downloading(Double)
        case checking
        case installed
        case failed(String)
    }

    /// One entry per manifest item that has been touched this session. Written only
    /// on the main queue; the delegate methods hop there to touch it.
    @Published private(set) var state: [String: State] = [:]

    /// Something changed on disk, so the model list and the engine's view of it are
    /// stale. The screen watches this rather than re-reading on every tick.
    @Published private(set) var installedSomething = 0

    private let queue = DispatchQueue(label: "com.example.offlinevoiceassistant.ios.models")

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        // A 1.3 GB file over a slow connection is not a hung request; the timeout
        // is about silence, not about total time.
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Downloads `item` unless it is already in flight.
    func download(_ item: ModelManifest.Item) {
        guard !isWorking(item.id) else { return }
        set(item.id, .downloading(0))
        let task = session.downloadTask(with: item.url)
        // The delegate gets the task, not the item, and this is the cheapest way to
        // carry the id across: `taskDescription` is a pass-through string, so no
        // shared dictionary has to be locked between the main queue and the
        // delegate's.
        task.taskDescription = item.id
        task.resume()
    }

    func cancel(_ id: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == id { task.cancel() }
        }
    }

    /// Whether anything is in flight, for the screen's "keep this open" hint.
    var isBusy: Bool {
        state.values.contains { if case .downloading = $0 { return true }; return $0 == .checking }
    }

    private func isWorking(_ id: String) -> Bool {
        switch state[id] {
        case .downloading, .checking: return true
        default: return false
        }
    }

    private func set(_ id: String, _ next: State) {
        DispatchQueue.main.async { self.state[id] = next }
    }

    /// Where a downloaded file goes: the same tree the engine is pointed at, so
    /// "downloaded" and "loadable" cannot come apart.
    private var root: URL { SharedStore.modelsRoot }
}

extension ModelDownloads: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64, totalBytesWritten written: Int64,
        totalBytesExpectedToWrite _: Int64
    ) {
        guard let id = downloadTask.taskDescription,
              let item = ModelManifest.item(id: id) else { return }
        set(id, .downloading(min(1, Double(written) / Double(max(1, item.bytes)))))
    }

    /// Verifies and moves, synchronously: the temporary file is deleted the moment
    /// this returns, so there is no second chance to check it.
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription,
              let item = ModelManifest.item(id: id) else { return }
        set(id, .checking)

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            set(id, .failed("伺服器回 \(http.statusCode)"))
            return
        }
        // Size first: it is the cheap check, and it is the one that catches the
        // common failure (a transfer that ended early).
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? NSNumber
        guard size?.int64Value == item.bytes else {
            set(id, .failed("大小不符：拿到 \(ModelManifest.size(size?.int64Value ?? 0))，"
                            + "清單說是 \(ModelManifest.size(item.bytes))"))
            return
        }
        guard let hash = try? ModelManifest.sha256(of: location), hash == item.sha256 else {
            set(id, .failed("SHA-256 不符，檔案沒有採用"))
            return
        }

        let dest = root.appendingPathComponent(item.file)
        do {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // A half-written file from an earlier attempt is replaced only now,
            // after this one has been proven -- never before.
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            set(id, .failed("存檔失敗：\(error.localizedDescription)"))
            return
        }
        set(id, .installed)
        DispatchQueue.main.async { self.installedSomething += 1 }
        Diagnostics.log.notice(
            "model installed: \(item.id, privacy: .public) → \(dest.path, privacy: .public)"
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            set(id, .failed("已取消"))
        } else {
            set(id, .failed("下載失敗：\(error.localizedDescription)"))
        }
    }
}
