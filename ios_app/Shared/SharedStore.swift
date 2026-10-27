import Foundation

/// The one thing the app and the keyboard share: the dictation session.
///
/// A keyboard extension cannot reach the microphone -- iOS refuses in CoreMedia,
/// before any permission prompt, and no entitlement changes it -- so the app owns
/// the recording. The keyboard's whole job is: say "start", watch the phase, and
/// type the result at the cursor. Both sides read and write the same App Group,
/// because that is the only channel that survives the app being in front.
///
/// `requestsOpenAccess` must be on for this group to exist at all. Without it the
/// container URL is nil and every write lands in a private store the other side
/// cannot see, which looks exactly like "the keyboard stopped receiving text".
enum SharedStore {
    static let appGroup = "group.com.example.offlinevoiceassistant"

    /// Darwin notification posted after every write. The keyboard is a separate
    /// process, so this is how it hears about a change in the same frame instead
    /// of on its next poll. Its only payload is the name; the state is in the
    /// group (Darwin notifications cannot carry a userInfo dictionary).
    static let notificationName = "com.example.offlinevoiceassistant.session"

    /// The other direction: the keyboard asking the app to start listening, used
    /// only in `.pip` mode where switching apps is exactly what must not happen.
    static let recordRequestName = "com.example.offlinevoiceassistant.record"

    enum Phase: String, Codable {
        case idle
        case recording
        case transcribing
        case refining
        case done
        case failed
    }

    struct Session: Codable {
        var phase: Phase = .idle
        /// Words the recogniser has settled on so far, while recording.
        var partial: String = ""
        /// Text ready to type at the cursor. Nil until the pipeline finishes.
        var text: String?
        /// One short line for the keyboard to show ("辨識中…", or a failure).
        var detail: String?
        /// Increments on every publish. The keyboard records the sequence it
        /// typed, so the same sentence cannot be typed twice -- and so a
        /// publish is idempotent across the two processes without a lock.
        var seq: Int = 0
        /// The last sequence the keyboard actually inserted.
        var consumedSeq: Int = 0
        var consumed: Bool { seq <= consumedSeq }
    }

    /// What `publish` writes, as one value.
    ///
    /// Text and sequence travel together on purpose: two separate keys could be
    /// read half-updated by the keyboard, and the failure that produces -- new
    /// text with the old sequence -- is silently *no insertion at all*. One key
    /// is one atomic write, so that state cannot exist.
    private struct Published: Codable {
        var seq: Int
        var text: String
        var detail: String?
    }

    // MARK: locations

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Nil when the App Group was never granted (Full Access off, or a build
    /// without the entitlement). Callers must not silently fall back: a private
    /// container looks identical to a working one until the other side is empty.
    static var sharedContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// The group container, or the private one only so that code paths that
    /// cannot run without *some* URL (model import) still have a target.
    static var container: URL {
        sharedContainer ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelsDir: URL { container.appendingPathComponent("models", isDirectory: true) }

    /// The same tree inside the app's own Documents.
    ///
    /// This is the one a phone user can actually reach: with file sharing on, it
    /// shows up under Finder › iPhone › Files › 語音輸入 and in the Files app, so
    /// models can be dragged in without an importer. Only the app ever reads a
    /// model -- the keyboard just inserts text -- so Documents is as good a home
    /// as the App Group, and it is the only one that can be installed into
    /// without the app running.
    static var documentsModels: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Where the models actually are, group first so an existing install keeps
    /// working after the Documents path was added.
    static var modelsRoot: URL {
        hasModels(at: modelsDir) || !hasModels(at: documentsModels) ? modelsDir : documentsModels
    }

    /// Where each kind of model belongs, under `modelsRoot`.
    static var asrDir: URL { modelsRoot.appendingPathComponent("asr/dolphin", isDirectory: true) }
    static var llmDir: URL { modelsRoot.appendingPathComponent("llm", isDirectory: true) }

    /// Creates the tree in both places before anything looks for a model.
    ///
    /// "The folder does not exist" and "the folder is empty" look identical in
    /// the UI and only the second one is actionable, so the folders are made
    /// first: on a phone the Documents copy is what the user opens in Files, and
    /// an empty but present `models/` is a place to put something.
    @discardableResult
    static func prepareModelDirs() -> Bool {
        let manager = FileManager.default
        var ok = true
        for root in [documentsModels, modelsDir] {
            for sub in ["asr/dolphin", "llm"] {
                do {
                    try manager.createDirectory(
                        at: root.appendingPathComponent(sub, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                } catch {
                    ok = false
                    // `Diagnostics` lives in the app target; this file is shared
                    // with the keyboard, which has no such type.
                    NSLog("ovc model dirs: %@", error.localizedDescription)
                }
            }
        }
        return ok
    }

    /// Either recogniser the core can drive: SenseVoice directly under `asr/`,
    /// or Dolphin in its own folder.
    ///
    /// The token table is part of the test, not an extra: the core requires
    /// `<model>` **and** `tokens.txt` side by side (`state.rs`), so a folder with
    /// only the `.onnx` in it makes `Agent_Load("asr")` fail at the first
    /// dictation. Counting that as "installed" would send the user into the
    /// recorder with a model screen that had nothing more to say, which is the
    /// one thing M5 exists to prevent.
    static func hasModels(at root: URL) -> Bool {
        let manager = FileManager.default
        func exists(_ relative: String) -> Bool {
            manager.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
        // Exactly the pairs the core will load (`state.rs`): SenseVoice is
        // `model.int8.onnx` or `model.onnx` with `tokens.txt` beside it, Dolphin
        // is `dolphin/model.int8.onnx` with its own `tokens.txt`. A looser test
        // here -- "any .onnx plus a tokens.txt" -- made the model screen say
        // 已安裝 for a folder the core rejects, and the rejection then surfaced at
        // the first dictation instead of on the screen whose job this is.
        let sense = (exists("asr/model.int8.onnx") || exists("asr/model.onnx"))
            && exists("asr/tokens.txt")
        let dolphin = exists("asr/dolphin/model.int8.onnx")
            && exists("asr/dolphin/tokens.txt")
        return sense || dolphin
    }

    static var hasModels: Bool { hasModels(at: modelsRoot) }

    /// Any GGUF in `llm/`. The engine falls back to the largest one it finds, so
    /// the app only has to know that the folder is not empty.
    static func hasLLM(at root: URL) -> Bool {
        let dir = root.appendingPathComponent("llm", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.lowercased().hasSuffix(".gguf") }
    }

    static var hasLLM: Bool { hasLLM(at: modelsRoot) }

    // MARK: session

    /// One key per field, and no read-modify-write across keys.
    ///
    /// All of this was a single JSON blob, which meant every writer -- both
    /// processes -- had to read the whole session, change one field and write it
    /// back. Two writes interleaved and the later one resurrects the earlier
    /// one's stale fields; the visible failure was a keyboard that stopped
    /// receiving live words because a `markConsumed` write had put the phase back
    /// to `.done`. Splitting the fields removes the shared mutable state instead
    /// of racing over it.
    private enum Key {
        static let phase = "s.phase"
        static let partial = "s.partial"
        static let detail = "s.detail"
        static let published = "s.published"
        static let consumedSeq = "s.consumedSeq"
        /// Monotonic publish counter, separate from the published blob so
        /// `clear()` cannot rewind it.
        static let seq = "s.seq"
        /// The old single-blob key, removed on `clear()` so an upgraded install
        /// does not keep a stale duplicate for ever.
        static let legacy = "session"
    }

    static func current() -> Session {
        guard let defaults else { return Session() }
        var session = Session()
        session.phase = defaults.string(forKey: Key.phase)
            .flatMap(Phase.init(rawValue:)) ?? .idle
        session.partial = defaults.string(forKey: Key.partial) ?? ""
        if let data = defaults.data(forKey: Key.published),
           let published = try? JSONDecoder().decode(Published.self, from: data) {
            session.text = published.text
            session.detail = published.detail ?? defaults.string(forKey: Key.detail)
            session.seq = published.seq
        } else {
            session.detail = defaults.string(forKey: Key.detail)
        }
        session.consumedSeq = defaults.integer(forKey: Key.consumedSeq)
        return session
    }

    /// Moves the phase without touching the published text, which is what a
    /// status update is. In particular it does **not** clear `text`: a sentence
    /// can be published before the keyboard gets a chance to type it, and a
    /// second dictation starting must not be what destroys the first one.
    static func setPhase(_ phase: Phase, detail: String? = nil) {
        guard let defaults else { post(); return }
        defaults.set(phase.rawValue, forKey: Key.phase)
        if let detail { defaults.set(detail, forKey: Key.detail) }
        else { defaults.removeObject(forKey: Key.detail) }
        post()
    }

    /// Live words while recording. Separate key from everything else: this runs
    /// four times a second and must not touch the phase or the published text.
    static func setPartial(_ text: String) {
        guard let defaults else { return }
        if phaseNow() != .recording { return }
        guard defaults.string(forKey: Key.partial) != text else { return }
        defaults.set(text, forKey: Key.partial)
        post()
    }

    private static func phaseNow() -> Phase {
        defaults?.string(forKey: Key.phase).flatMap(Phase.init(rawValue:)) ?? .idle
    }

    /// Publishes the finished text. One atomic write carrying its own sequence,
    /// so the keyboard can tell "the same sentence again" from "a new one".
    static func publish(_ text: String, detail: String? = nil) {
        guard let defaults else { post(); return }
        let previous = current()
        if !previous.consumed, let lost = previous.text, !lost.isEmpty {
            // A second sentence landed before the keyboard typed the first. The
            // handoff is a single slot by design; saying so in the log is the
            // honest end of it rather than pretending the queue exists.
            NSLog("ovc publish: overwriting an unconsumed transcript (%d chars)", lost.count)
        }
        // The counter lives on its own key and is never reset. Deriving the next
        // sequence from the published blob meant `clear()` -- which deletes it --
        // restarted numbering at 1, so a keyboard that had already typed
        // sequence 3 went on ignoring new sentences until the count climbed back
        // past it: three dictations vanishing with nothing on screen to explain
        // it. A monotonic counter cannot go backwards, so `seq > consumedSeq`
        // stays a true statement about time.
        //
        // `max` with the published sequence covers the upgrade: an install from
        // before this key existed has `s.consumedSeq = 3` and no `s.seq`, and
        // starting that one at 1 would reintroduce the very bug on the first
        // launch after the update. `consumedSeq` is included for the same reason
        // one step further out: anything that resets the counter (a restored
        // backup, a repair that clears two keys but not the third) still cannot
        // produce a sequence the keyboard has already typed.
        let seq = max(defaults.integer(forKey: Key.seq), previous.seq, previous.consumedSeq) + 1
        let next = Published(seq: seq, text: text, detail: detail ?? "已整理完成")
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Key.published)
        }
        defaults.set(seq, forKey: Key.seq)
        defaults.set(Phase.done.rawValue, forKey: Key.phase)
        defaults.set(next.detail ?? "", forKey: Key.detail)
        post()
    }

    /// Text the keyboard has not typed yet, with the sequence that identifies it.
    static func pending() -> (text: String, seq: Int)? {
        let session = current()
        guard !session.consumed, let text = session.text, !text.isEmpty else { return nil }
        return (text, session.seq)
    }

    static func pendingText() -> String? { pending()?.text }

    /// Called after `insertText` succeeded. Writes one integer, so it cannot
    /// clobber anything the app wrote in the meantime. Writing this before
    /// inserting is how a handoff gets lost silently, so the order matters.
    static func markConsumed(_ seq: Int? = nil) {
        guard let defaults else { return }
        let value = seq ?? current().seq
        defaults.set(value, forKey: Key.consumedSeq)
        post()
    }

    static func clear() {
        guard let defaults else { post(); return }
        defaults.set(Phase.idle.rawValue, forKey: Key.phase)
        defaults.removeObject(forKey: Key.detail)
        defaults.removeObject(forKey: Key.partial)
        defaults.removeObject(forKey: Key.published)
        defaults.removeObject(forKey: Key.legacy)
        // Deliberately not touching `s.seq` or `s.consumedSeq`: both only ever
        // move forward, and resetting either is what would make a sequence
        // number mean two different sentences.
        post()
    }

    // MARK: settings

    /// The cleanup pass, on by default. Off is the honest option for a user who
    /// wants the words exactly as the recogniser heard them, and it is also how
    /// the two are compared on the same recording.
    static var refineEnabled: Bool {
        get {
            guard let defaults else { return true }
            if defaults.object(forKey: "refine") == nil { return true }
            return defaults.bool(forKey: "refine")
        }
        set { defaults?.set(newValue, forKey: "refine") }
    }

    /// How the keyboard asks for a dictation.
    ///
    /// `.toApp` is the default and cannot fail: the keyboard opens `ovc://record`,
    /// iOS switches apps, and the recording happens in front of the user.
    ///
    /// `.pip` is the Typeless shape -- stay in the app you were typing in, and let
    /// a picture-in-picture window keep this app alive in the background while it
    /// records. It only works once PiP has actually started (`PiPController.
    /// isLive`), so the keyboard falls back to `.toApp` when it has not: honouring
    /// the setting blindly would leave a microphone button that does nothing.
    enum Mode: String {
        case toApp
        case pip
    }

    static var mode: Mode {
        get {
            guard let raw = defaults?.string(forKey: "mode"), let mode = Mode(rawValue: raw) else {
                return .toApp
            }
            return mode
        }
        set { defaults?.set(newValue.rawValue, forKey: "mode") }
    }

    /// Whether the PiP window is actually up right now.
    ///
    /// The keyboard cannot see the app, so a mode that was chosen but is not
    /// running has to be distinguishable from one that is -- otherwise Mode 2
    /// turns the microphone button into a no-op on a device that refused PiP.
    ///
    /// A flag alone was not enough: it is written by delegate callbacks, and a
    /// process the system kills never runs them, so a dead app left `true`
    /// behind for ever and the microphone button became exactly the dead button
    /// this check exists to prevent. The app now stamps `pipLiveAt` while the
    /// window is up and the keyboard only trusts a recent stamp.
    static var pipLive: Bool {
        get { defaults?.bool(forKey: "pipLive") ?? false }
        set {
            defaults?.set(newValue, forKey: "pipLive")
            if newValue { stampPiP() } else { defaults?.removeObject(forKey: "pipLiveAt") }
        }
    }

    /// How long a PiP stamp stays believable. The app refreshes it every second,
    /// so this is a long grace period rather than a race: a main thread busy with
    /// a model import can stall for several seconds, and a keyboard that declares
    /// the window dead then forces an app switch the user did not need. A killed
    /// app still stops swallowing microphone taps within twenty seconds.
    private static let pipFreshness: Double = 20

    static func stampPiP() {
        // Also asserts the flag: a fresh stamp is a live window, and writing both
        // means the app restarting its own heartbeat repairs a flag that was
        // cleared by a launch while the window was still up.
        defaults?.set(true, forKey: "pipLive")
        defaults?.set(Date().timeIntervalSince1970, forKey: "pipLiveAt")
    }

    /// `pipLive` and recently stamped. This is what the keyboard must ask.
    static var pipAlive: Bool {
        guard pipLive, let at = defaults?.object(forKey: "pipLiveAt") as? Double else {
            return false
        }
        return Date().timeIntervalSince1970 - at < pipFreshness
    }

    // MARK: notification

    /// The keyboard's "start listening" request, used in `.pip` mode.
    ///
    /// A Darwin notification rather than the URL scheme: a URL switch would leave
    /// the app the user is typing in, which is the one thing this mode exists to
    /// avoid.
    static func requestRecording() {
        post(name: recordRequestName)
    }

    /// Runs `handler` on the main queue when the keyboard asks for a recording.
    static func observeRecordRequest(_ handler: @escaping () -> Void) {
        RecordRequest.handler = handler
        guard !RecordRequest.registered, let center = poster else { return }
        RecordRequest.registered = true
        let observer = Unmanaged.passUnretained(RecordRequest.shared).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async { RecordRequest.handler?() }
            },
            recordRequestName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private final class RecordRequest {
        static let shared = RecordRequest()
        static var handler: (() -> Void)?
        static var registered = false
    }

    // MARK: notification

    private static let poster: CFNotificationCenter? = CFNotificationCenterGetDarwinNotifyCenter()

    static func post() {
        post(name: notificationName)
    }

    private static func post(name: String) {
        guard let center = poster else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Runs `handler` on the main queue whenever the other process writes.
    /// Ignored without a group container: nothing can arrive anyway.
    static func observe(_ handler: @escaping () -> Void) {
        Notify.handler = handler
        guard !Notify.registered, poster != nil else { return }
        Notify.registered = true
        let center = poster!
        let observer = Unmanaged.passUnretained(Notify.shared).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async { Notify.handler?() }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Holds the callback for the C function above, which cannot capture one.
    private final class Notify {
        static let shared = Notify()
        static var handler: (() -> Void)?
        static var registered = false
    }
}
