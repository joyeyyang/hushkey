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

    /// Either recogniser the core can drive: SenseVoice directly under `asr/`,
    /// or Dolphin in its own folder.
    static var hasModels: Bool {
        let manager = FileManager.default
        let sense = modelsDir.appendingPathComponent("asr/model.int8.onnx")
        let dolphin = modelsDir.appendingPathComponent("asr/dolphin/model.int8.onnx")
        return manager.fileExists(atPath: sense.path) || manager.fileExists(atPath: dolphin.path)
    }

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

    // MARK: notification

    private static let poster: CFNotificationCenter? = CFNotificationCenterGetDarwinNotifyCenter()

    static func post() {
        guard let center = poster else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(notificationName as CFString),
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
