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
        var updatedAt: Double = 0
        var consumed: Bool = false
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
    static func hasModels(at root: URL) -> Bool {
        let manager = FileManager.default
        let sense = root.appendingPathComponent("asr/model.int8.onnx")
        let dolphin = root.appendingPathComponent("asr/dolphin/model.int8.onnx")
        return manager.fileExists(atPath: sense.path) || manager.fileExists(atPath: dolphin.path)
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

    private static let key = "session"

    static func current() -> Session {
        guard let data = defaults?.data(forKey: key),
              let session = try? JSONDecoder().decode(Session.self, from: data)
        else { return Session() }
        return session
    }

    static func save(_ session: Session) {
        var copy = session
        copy.updatedAt = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(copy) {
            defaults?.set(data, forKey: key)
        }
        post()
    }

    /// Moves the phase without touching the text, which is what a status update is.
    static func setPhase(_ phase: Phase, detail: String? = nil) {
        var session = current()
        session.phase = phase
        session.detail = detail
        if phase != .done { session.text = nil }
        session.consumed = false
        save(session)
    }

    /// Live words while recording. Separate from `setPhase` because this runs
    /// several times a second and must not reset the text or the consumed flag.
    static func setPartial(_ text: String) {
        var session = current()
        guard session.phase == .recording else { return }
        guard session.partial != text else { return }
        session.partial = text
        save(session)
    }

    /// Publishes the finished text. `consumed` starts false so the keyboard types
    /// it exactly once, and only after it actually reached the cursor.
    static func publish(_ text: String, detail: String? = nil) {
        var session = Session()
        session.phase = .done
        session.text = text
        session.detail = detail ?? "已整理完成"
        session.consumed = false
        save(session)
    }

    /// Text the keyboard has not typed yet, if any.
    static func pendingText() -> String? {
        let session = current()
        guard session.phase == .done, !session.consumed,
              let text = session.text, !text.isEmpty
        else { return nil }
        return text
    }

    /// Called after `insertText` succeeded. Writing this before inserting is how
    /// a handoff gets lost silently, so the order matters.
    static func markConsumed() {
        var session = current()
        session.consumed = true
        save(session)
    }

    static func clear() {
        save(Session())
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
    static var pipLive: Bool {
        get { defaults?.bool(forKey: "pipLive") ?? false }
        set { defaults?.set(newValue, forKey: "pipLive") }
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
