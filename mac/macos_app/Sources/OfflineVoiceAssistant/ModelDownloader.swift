import Foundation

/// Downloads one manifest row into the models directory.
///
/// The file is streamed by `URLSession` and lands under `<file>.part`; only after the
/// byte count *and* the SHA-256 both match does it move into place, so a truncated or
/// substituted download never appears under the model's real name. There is no resume:
/// an interrupted download restarts from zero, and a `.part` left by an interrupted run
/// is discarded before the next attempt.
///
/// `progress` and `completion` are delivered on a private serial background queue, so
/// callers hop to the main queue before touching UI.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    struct Progress: Sendable {
        let received: Int64
        let total: Int64
        /// Rate over the last few seconds, not the average since the start.
        let bytesPerSecond: Double
        /// Seconds left at the current rate; nil until the rate means something.
        let eta: TimeInterval?

        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    enum DownloadError: Error, CustomStringConvertible {
        case http(Int)
        case sizeMismatch(expected: Int64, got: Int64)
        case hashMismatch
        case cancelled
        case diskFull
        /// Nothing fetchable: no source URL, a digest that cannot be verified (the
        /// manifest's "PENDING"), or a second `start()` on the same downloader.
        case invalidRequest(String)
        /// The server tried to send us off HTTPS. We refuse instead of downgrading.
        case insecureRedirect(String)

        var description: String {
            switch self {
            case let .http(code):
                return "download failed with HTTP \(code)"
            case let .sizeMismatch(expected, got):
                return "downloaded \(got) bytes, expected \(expected)"
            case .hashMismatch:
                return "download failed SHA-256 verification"
            case .cancelled:
                return "download cancelled"
            case .diskFull:
                return "not enough free disk space for the download"
            case let .invalidRequest(why):
                return "cannot download: \(why)"
            case let .insecureRedirect(url):
                return "refused to follow a non-HTTPS redirect to \(url)"
            }
        }
    }

    /// The rate window. Averaging over the whole transfer reads wrong on a link that
    /// starts fast and then stalls; a window slides past the fast start and the rate
    /// decays to what is actually happening now.
    private static let windowSeconds: Double = 5
    /// Progress is reported at most this often, so the UI is not flooded.
    private static let emitInterval: TimeInterval = 0.25
    /// How much sample history is kept to find a window baseline in.
    private static let historySeconds: Double = 30

    private let entry: ModelEntry
    private let destinationDirectory: URL

    /// Serial queue used both as the session's delegate queue and to deliver callbacks.
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.openypeless.model-downloader"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var progressHandler: (@Sendable (Progress) -> Void)?
    private var completionHandler: (@Sendable (Result<URL, Error>) -> Void)?
    private var started = false
    private var finished = false

    private struct Sample {
        let time: UInt64
        let bytes: Int64
    }
    private var samples: [Sample] = []
    private var lastEmit: UInt64 = 0

    /// Where the verified file ends up.
    var destinationURL: URL { destinationDirectory.appendingPathComponent(entry.file) }
    /// Where it downloads to first. Visible only until the digest checks out.
    var partialURL: URL { URL(fileURLWithPath: destinationURL.path + ".part") }

    init(entry: ModelEntry, destinationDirectory: URL) {
        self.entry = entry
        self.destinationDirectory = destinationDirectory
        super.init()
    }

    // MARK: - Lifecycle

    func start(progress: @escaping @Sendable (Progress) -> Void,
               completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        lock.lock()
        let duplicate = started
        if !duplicate {
            started = true
            progressHandler = progress
            completionHandler = completion
        }
        lock.unlock()

        guard !duplicate else {
            completion(.failure(DownloadError.invalidRequest(
                "\(entry.id) is already downloading in this downloader")))
            return
        }

        let request: URLRequest
        do {
            request = try makeRequest()
            try prepareDestination()
        } catch {
            finish(.failure(error))
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: workQueue)
        let task = session.downloadTask(with: request)

        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()

        task.resume()
    }

    /// Cancels an in-flight download and reports `DownloadError.cancelled`. Safe to call
    /// from any thread, and safe to call more than once.
    func cancel() {
        lock.lock()
        let task = self.task
        let session = self.session
        let live = started && !finished
        lock.unlock()

        guard live else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        finish(.failure(DownloadError.cancelled))
    }

    private func makeRequest() throws -> URLRequest {
        guard let source = entry.sourceURL else {
            throw DownloadError.invalidRequest("\(entry.id) has no source URL")
        }
        guard source.scheme?.lowercased() == "https" else {
            throw DownloadError.invalidRequest(
                "\(entry.id) is not served over HTTPS (\(source.absoluteString))")
        }
        guard entry.hasVerifiableDigest else {
            throw DownloadError.invalidRequest(
                "\(entry.id) has no verifiable digest (\(entry.sha256))")
        }
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        return request
    }

    /// Creates the folder, drops a stale partial, and refuses to start when the disk
    /// cannot hold the file.
    private func prepareDestination() throws {
        let fm = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: partialURL)

        guard entry.bytes > 0 else { return }
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free >= 0,
           free < entry.bytes {
            throw DownloadError.diskFull
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : entry.bytes
        let now = DispatchTime.now().uptimeNanoseconds

        samples.append(Sample(time: now, bytes: written))
        pruneSamples(now: now)

        let (rate, eta) = estimate(now: now, written: written, total: total)

        // Throttle, but always let the final tick through so the bar can sit at 100%.
        guard now - lastEmit >= UInt64(Self.emitInterval * 1e9) || written >= total else { return }
        lastEmit = now
        progressHandler?(Progress(received: written, total: total,
                                  bytesPerSecond: rate, eta: eta))
    }

    /// The location is deleted as soon as this returns, so verify and move here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw DownloadError.http(http.statusCode)
            }
            let expected = entry.bytes
            let got = try size(of: location)
            guard expected <= 0 || got == expected else {
                throw DownloadError.sizeMismatch(expected: expected, got: got)
            }

            let fm = FileManager.default
            try? fm.removeItem(at: partialURL)
            try fm.moveItem(at: location, to: partialURL)

            // Hash the partial, so a bad file never has a window under the real name.
            let digest = try ModelCatalog.sha256(of: partialURL)
            guard digest == entry.sha256.lowercased() else {
                throw DownloadError.hashMismatch
            }

            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: partialURL)
            } else {
                try fm.moveItem(at: partialURL, to: destinationURL)
            }
            finish(.success(destinationURL))
        } catch {
            // `finish` drops the partial on any failure.
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // A success is reported from didFinishDownloadingTo; reaching here with no
            // error and no file means the server answered without a body.
            finish(.failure(DownloadError.invalidRequest("the download ended without a file")))
            return
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
            finish(.failure(DownloadError.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    /// Hugging Face hands out its artifacts from a signed CDN URL over a redirect.
    /// Following one to plain HTTP would drop the transport security that the digest
    /// alone does not replace, so refuse and fail.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            finish(.failure(DownloadError.insecureRedirect(request.url?.absoluteString ?? "?")))
            task.cancel()
            return
        }
        completionHandler(request)
    }

    // MARK: - Rate estimation

    private func pruneSamples(now: UInt64) {
        let horizon = UInt64(Self.historySeconds * 1e9)
        let cutoff = now > horizon ? now - horizon : 0
        while samples.count > 1, let first = samples.first, first.time < cutoff {
            samples.removeFirst()
        }
    }

    /// Rate over the last `windowSeconds`, from the newest sample at or before the
    /// window's start as the baseline — or the oldest sample when the window is not
    /// full yet. A stalled link stops adding bytes while the baseline keeps moving
    /// forward, so the rate decays instead of reporting the average of a fast start.
    private func estimate(now: UInt64, written: Int64, total: Int64) -> (Double, TimeInterval?) {
        guard let oldest = samples.first else { return (0, nil) }
        let windowStart = now > UInt64(Self.windowSeconds * 1e9) ? now - UInt64(Self.windowSeconds * 1e9) : 0
        let baseline = samples.last { $0.time <= windowStart } ?? oldest
        let seconds = Double(now - baseline.time) / 1e9
        guard seconds > 0.05, written > baseline.bytes else { return (0, nil) }
        let rate = Double(written - baseline.bytes) / seconds
        guard rate > 0.5 else { return (rate, nil) }
        let remaining = Double(total - written)
        return (rate, remaining > 0 ? remaining / rate : 0)
    }

    // MARK: - Finishing

    private func size(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func partialCleanup() {
        try? FileManager.default.removeItem(at: partialURL)
    }

    /// Delivers exactly one terminal result, on `workQueue`.
    private func finish(_ result: Result<URL, Error>) {
        workQueue.addOperation { [self] in
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let completion = completionHandler
            let session = self.session
            completionHandler = nil
            progressHandler = nil
            self.session = nil
            task = nil
            lock.unlock()

            session?.invalidateAndCancel()
            if case .failure = result { partialCleanup() }
            completion?(result)
        }
    }

    // MARK: - Removal

    /// Removes the model from disk, and any stale partial beside it.
    ///
    /// Refuses to remove the currently selected LLM: `currentFileName` names the model
    /// the engine would load, and deleting it mid-session turns the next refine pass
    /// into a failure rather than a fallback. Select another LLM first.
    static func delete(_ entry: ModelEntry) throws {
        guard ModelCatalog.relativePathIsSafe(entry.file) else {
            throw ModelCatalog.CatalogError.unsafePath(entry.file)
        }
        guard !LLMSelection.isSelected(entry) else {
            throw ModelCatalog.CatalogError.selectedModel(entry.file)
        }
        let fm = FileManager.default
        let file = ModelCatalog.modelsDirectory().appendingPathComponent(entry.file)
        let part = URL(fileURLWithPath: file.path + ".part")
        for url in [file, part] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
