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

    /// Pause and resume, also asked for from the keyboard.
    ///
    /// Same channel as `recordRequestName` and for the same reason: the keyboard
    /// owns no microphone, so every microphone decision is a message to the app.
    /// These two matter more than they look. In Mode 1 the app is backgrounded
    /// while it records, and the silence gate auto-stops after 1.2 seconds -- so
    /// without a pause the only way to hold a sentence together through an
    /// interruption is to keep talking.
    static let pauseRequestName = "com.example.offlinevoiceassistant.pause"
    static let resumeRequestName = "com.example.offlinevoiceassistant.resume"

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
    /// shows up under Finder › iPhone › Files › Hushkey and in the Files app, so
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
        /// Whether the microphone is held but not listening.
        ///
        /// Its own key rather than a seventh `Phase`: "paused" is not a stage of
        /// the pipeline, it is a property of the recording, and folding it into
        /// `Phase` would mean every `switch` in both processes grew a case that
        /// behaves exactly like `.recording` except in the two places it does not.
        static let paused = "s.paused"
        /// The keyboard's record requests, and how many the app has acted on.
        ///
        /// A pair of monotonic counters, like `s.seq`/`s.consumedSeq` and for the
        /// same reason: "there is a request the app has not seen" has to survive
        /// both processes being killed at any moment, and a boolean cannot say it
        /// -- the app clearing a flag would also erase a request that arrived in
        /// between.
        static let recordRequest = "s.recordRequest"
        static let recordRequestConsumed = "s.recordRequestConsumed"
        /// When the newest request was made, so a stale one can be told from the tap
        /// the user is making now.
        static let recordRequestAt = "s.recordRequestAt"
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

    // MARK: keyboard edit (修改的提示詞)

    /// One 修改的提示詞, written by the keyboard and acted on by the app.
    ///
    /// The keyboard cannot run the model: an extension gets tens of megabytes
    /// before the system kills it, and the LLM alone is several hundred. So the
    /// panel asks, the app answers -- and both sides need the request to survive
    /// the app being suspended, the keyboard being dismissed while it works, and
    /// the notification nobody was listening for. That is a value in the group,
    /// not a message in flight.
    struct EditRequest: Codable, Equatable {
        /// Monotonic, so a reply can be matched to the question it answers.
        var seq: Int
        /// The text the user wants changed. For the keyboard panel this is the
        /// sentence the keyboard last typed, because that is the only text it
        /// knows the exact position of.
        var draft: String
        /// What to change, verbatim: the user's own words, never paraphrased.
        var instruction: String
        var at: Double
        /// Which part of the draft the instruction is about: "whole", "line" or
        /// "selection". Optional because requests written before the region
        /// picker existed carry no such key, and a decode failure would strand
        /// them in the group forever.
        var region: String?
        /// The 1-based line for `region == "line"`; 0 or nil otherwise.
        var line: Int?
        /// The text the user selected in the document, for `region ==
        /// "selection"`. The app finds it in the draft and edits only that slice.
        var selection: String?
    }

    /// The app's answer to one `EditRequest`. `text` and `error` are exclusive;
    /// both nil means "still working", which the keyboard reads as nothing.
    struct EditResult: Codable, Equatable {
        var seq: Int
        var text: String?
        var error: String?
    }

    /// The app heard the request and is working on it.
    ///
    /// Separate from the result because the two answer different questions, and
    /// the keyboard has to act on them differently: no acknowledgement means the
    /// app is not running (say so, offer to open it), no result yet means it is
    /// running and slow (keep waiting). An edit takes ~20 seconds on a phone --
    /// the model is loaded per call -- so a single timeout cannot tell those
    /// apart without either lying to the user or giving up on a working edit.
    static let editRequestName = "com.example.offlinevoiceassistant.edit"
    static let editResultName = "com.example.offlinevoiceassistant.editResult"

    private enum EditKey {
        static let request = "e.request"
        static let consumed = "e.consumed"
        static let ack = "e.ack"
        static let response = "e.response"
        /// The newest answer the keyboard has already put into the document.
        ///
        /// In Mode 1 the edit opens the app and the keyboard is destroyed, so the
        /// answer arrives in a NEW extension process that has no memory of asking.
        /// Without this key it would sit in the group unapplied -- the user comes
        /// back to the text they had, with no sign that anything was answered.
        static let applied = "e.applied"
        /// A dictation the keyboard asked for in order to fill its instruction
        /// field, rather than to type at the cursor.
        ///
        /// In the group rather than in the extension's memory: in Mode 1 the
        /// microphone opens the app, which destroys the keyboard, and the answer
        /// arrives in a new process that has no memory of having asked.
        static let instructionDictation = "s.instructionDictation"
        static let instructionDraft = "s.instructionDraft"
    }

    /// Writes the request and announces it. Returns the sequence to wait on.
    ///
    /// `region` is "whole" / "line" / "selection"; `selection` is the selected
    /// text, needed only for the last one. Both default to the whole draft, which
    /// is what the panel did before it had a region picker.
    @discardableResult
    static func requestEdit(draft: String, instruction: String,
                            region: String = "whole", line: Int = 0,
                            selection: String? = nil) -> Int {
        guard let defaults else { return 0 }
        let previous = defaults.data(forKey: EditKey.request)
            .flatMap { try? JSONDecoder().decode(EditRequest.self, from: $0) }
        let seq = max(
            previous?.seq ?? 0,
            defaults.integer(forKey: EditKey.consumed),
            defaults.integer(forKey: EditKey.ack)
        ) + 1
        let request = EditRequest(
            seq: seq, draft: draft, instruction: instruction,
            at: Date().timeIntervalSince1970,
            region: region, line: line, selection: selection
        )
        if let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: EditKey.request)
        }
        post(name: editRequestName)
        return seq
    }

    /// A request the app has not consumed. Nil when there is none.
    static var pendingEditRequest: EditRequest? {
        guard let defaults,
              let data = defaults.data(forKey: EditKey.request),
              let request = try? JSONDecoder().decode(EditRequest.self, from: data),
              request.seq > defaults.integer(forKey: EditKey.consumed)
        else { return nil }
        return request
    }

    /// Whether the pending request is recent enough to act on without being
    /// asked to. The prompted channels (the URL, the notification) are being
    /// delivered now; a launch or coming back to the app is not evidence of a
    /// new tap, so those only honour a request that is still warm.
    static func hasFreshEditRequest(within seconds: TimeInterval = 120) -> Bool {
        guard let request = pendingEditRequest else { return false }
        return Date().timeIntervalSince1970 - request.at < seconds
    }

    /// Called by whoever acts on the request, before acting: two channels can
    /// deliver the same request, and the second one must not run the model again.
    static func consumeEditRequest(_ seq: Int) {
        defaults?.set(seq, forKey: EditKey.consumed)
    }

    /// "I have it." Written before the model is called, so the keyboard can tell
    /// "the app is not running" from "the app is thinking".
    static func ackEditRequest(_ seq: Int) {
        guard let defaults else { post(name: editResultName); return }
        defaults.set(seq, forKey: EditKey.ack)
        post(name: editResultName)
    }

    static var editAckedSeq: Int {
        defaults?.integer(forKey: EditKey.ack) ?? 0
    }

    /// The answer, or an error the panel can show. `text` nil with an `error`
    /// means the edit was refused; both nil is never written.
    static func publishEditResult(seq: Int, text: String?, error: String?) {
        guard let defaults else { post(name: editResultName); return }
        let result = EditResult(seq: seq, text: text, error: error)
        if let data = try? JSONEncoder().encode(result) {
            defaults.set(data, forKey: EditKey.response)
        }
        post(name: editResultName)
    }

    /// The answer to `seq`, or nil while there is none.
    ///
    /// Matched on the sequence rather than "the last result": the keyboard may
    /// still be waiting on an older request when a newer one is answered, and
    /// applying the wrong sentence to the wrong text is worse than waiting.
    static func editResult(for seq: Int) -> EditResult? {
        guard let defaults,
              let data = defaults.data(forKey: EditKey.response),
              let result = try? JSONDecoder().decode(EditResult.self, from: data),
              result.seq == seq,
              result.text != nil || result.error != nil
        else { return nil }
        return result
    }

    /// An answer the keyboard has not put into the document yet, with the draft
    /// it belongs to.
    ///
    /// Read on every appearance, not only while waiting: a keyboard recreated
    /// after an app switch has no `seq` in memory, and this is the only thing
    /// that can tell it there is an answer to apply.
    static func unappliedEditResult() -> (result: EditResult, draft: String)? {
        guard let defaults,
              let responseData = defaults.data(forKey: EditKey.response),
              let result = try? JSONDecoder().decode(EditResult.self, from: responseData),
              result.seq > defaults.integer(forKey: EditKey.applied),
              let requestData = defaults.data(forKey: EditKey.request),
              let request = try? JSONDecoder().decode(EditRequest.self, from: requestData),
              request.seq == result.seq,
              result.text != nil || result.error != nil
        else { return nil }
        return (result, request.draft)
    }

    /// Called after the answer was inserted (or copied, or shown as a failure),
    /// so the same answer cannot be applied twice by two paths.
    static func markEditApplied(_ seq: Int) {
        defaults?.set(seq, forKey: EditKey.applied)
    }

    /// Marks the next published dictation as an instruction for the panel.
    static var instructionDictation: Bool {
        get { defaults?.bool(forKey: EditKey.instructionDictation) ?? false }
        set { defaults?.set(newValue, forKey: EditKey.instructionDictation) }
    }

    /// The text the instruction is about, kept beside the flag.
    ///
    /// In Mode 1 the microphone opens the app and the keyboard is destroyed, so
    /// the sentence that was on screen when 用說的 was tapped has to be in the
    /// group as well -- otherwise the instruction comes back to a panel with
    /// nothing to apply it to.
    static var instructionDictationDraft: String {
        get { defaults?.string(forKey: EditKey.instructionDraft) ?? "" }
        set { defaults?.set(newValue, forKey: EditKey.instructionDraft) }
    }

    /// Runs `handler` on the main queue when the keyboard asks for an edit.
    static func observeEditRequest(_ handler: @escaping () -> Void) {
        EditRequestWatch.handler = handler
        guard !EditRequestWatch.registered, let center = poster else { return }
        EditRequestWatch.registered = true
        let observer = Unmanaged.passUnretained(EditRequestWatch.shared).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async { EditRequestWatch.handler?() }
            },
            editRequestName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private final class EditRequestWatch {
        static let shared = EditRequestWatch()
        static var handler: (() -> Void)?
        static var registered = false
    }

    /// Runs `handler` on the main queue when the app acknowledges or answers.
    static func observeEditResult(_ handler: @escaping () -> Void) {
        EditResultWatch.handler = handler
        guard !EditResultWatch.registered, let center = poster else { return }
        EditResultWatch.registered = true
        let observer = Unmanaged.passUnretained(EditResultWatch.shared).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                DispatchQueue.main.async { EditResultWatch.handler?() }
            },
            editResultName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private final class EditResultWatch {
        static let shared = EditResultWatch()
        static var handler: (() -> Void)?
        static var registered = false
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

    /// The register the cleanup writes in: "casual", "normal" (the default) or
    /// "formal".
    ///
    /// Lives here rather than in `Preferences` because it is a setting the
    /// keyboard has an opinion about too (the 修改提示詞 panel is the keyboard's
    /// own surface), and the App Group defaults are the only store both
    /// processes can read. The core treats an unknown value as "normal", so a
    /// value written by an older build costs the register, never the dictation.
    static var refineTone: String {
        get { defaults?.string(forKey: "refineTone") ?? "normal" }
        set { defaults?.set(newValue, forKey: "refineTone") }
    }

    /// 貼上前確認: hold the dictated sentence until the user taps 插入, instead of
    /// typing it at the cursor the moment it comes back.
    ///
    /// In the App Group, not the app's own defaults, because the keyboard is the
    /// side that acts on it -- and a keyboard extension reads nothing else. Off by
    /// default, the same as the Mac's `settings.confirmInsert`: a product whose
    /// first dictation does nothing visible until a second tap would look broken.
    static var confirmBeforeInsert: Bool {
        get { defaults?.bool(forKey: "confirmBeforeInsert") ?? false }
        set { defaults?.set(newValue, forKey: "confirmBeforeInsert") }
    }

    /// Which paper the app draws with: "paper", "night", "slate", "moss",
    /// "clay", or "system" (the default, as on the Mac) to follow the phone's
    /// appearance.
    ///
    /// Lives in the App Group next to the other settings rather than in
    /// `Preferences`, because it is the same kind of value as the register: a
    /// choice the user made that the other process may need to read. The
    /// keyboard draws its own chrome today, so nothing else reads it yet -- but a
    /// setting that lives only in the app's own defaults is one the keyboard can
    /// never honour later.
    static var themeID: String {
        get { defaults?.string(forKey: "themeID") ?? "system" }
        set { defaults?.set(newValue, forKey: "themeID") }
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

    /// The keyboard asking for a dictation, written down as well as announced.
    ///
    /// The notification alone was not enough, and the failure it left was the one
    /// the user reported: the keyboard tapped, the app was already running but in
    /// the background, and nothing happened. A Darwin notification only reaches a
    /// listening process, and `extensionContext.open(url)` -- the other channel --
    /// returns **false** in exactly that situation (iOS declines the open when the
    /// containing app is resident), which the keyboard used to report as "the app
    /// is not open". It was open.
    ///
    /// So the request is also written to the group, with a sequence that only ever
    /// moves forward. Whichever channel survives -- the URL, the notification, or
    /// the app finding it the next time it becomes active -- the request is there
    /// to be found, and any of them can be the one that arrives.
    static func requestRecording() {
        // Written first, then announced: a handler that reacts to the notification
        // reads the request, and a handler that ran before the write would find
        // nothing and drop a tap the user already made.
        if let defaults {
            let next = max(
                defaults.integer(forKey: Key.recordRequest),
                defaults.integer(forKey: Key.recordRequestConsumed)
            ) + 1
            defaults.set(next, forKey: Key.recordRequest)
            defaults.set(Date().timeIntervalSince1970, forKey: Key.recordRequestAt)
        }
        post(name: recordRequestName)
    }

    /// A request young enough to act on without being asked.
    ///
    /// A request the app never got to -- the process was killed between the tap and
    /// the start -- stays in the group, which is what makes it survive at all. But
    /// the app also checks for one every time it becomes active, and opening the app
    /// to read the history a week later must not start a recording. So the
    /// unprompted paths (a launch, coming back to the app) only honour a request
    /// that is still recent; the prompted ones (the URL, the notification) are being
    /// delivered now and need no such test.
    static func hasFreshRecordRequest(within seconds: TimeInterval = 120) -> Bool {
        guard hasPendingRecordRequest,
              let at = defaults?.object(forKey: Key.recordRequestAt) as? Double
        else { return false }
        return Date().timeIntervalSince1970 - at < seconds
    }

    /// Whether the keyboard has asked for a dictation the app has not acted on.
    ///
    /// The app asks this when it becomes active, which is how a request survives a
    /// process that was not running, an `open()` iOS refused, and a notification
    /// nobody was listening for.
    static var hasPendingRecordRequest: Bool {
        guard let defaults else { return false }
        return defaults.integer(forKey: Key.recordRequest)
            > defaults.integer(forKey: Key.recordRequestConsumed)
    }

    /// Called by whoever acts on the request, before acting: the three channels all
    /// lead here, and without this the second one to arrive would start a second
    /// dictation into a pipeline that already has one.
    static func consumeRecordRequest() {
        guard let defaults else { return }
        defaults.set(defaults.integer(forKey: Key.recordRequest), forKey: Key.recordRequestConsumed)
    }

    /// Whether the microphone is open but not listening.
    static var isPaused: Bool {
        get { defaults?.bool(forKey: Key.paused) ?? false }
        set {
            defaults?.set(newValue, forKey: Key.paused)
            post()
        }
    }

    /// The keyboard's pause / resume buttons.
    static func requestPause() { post(name: pauseRequestName) }
    static func requestResume() { post(name: resumeRequestName) }

    /// Runs `handler` on the main queue when the keyboard asks to pause or resume.
    ///
    /// One registration for both, because they are one decision: a keyboard that
    /// hears "pause" but not "resume" leaves a button that can only ever stop
    /// listening. The handler is handed `true` for pause.
    static func observePauseRequest(_ handler: @escaping (Bool) -> Void) {
        PauseRequest.handler = handler
        guard !PauseRequest.registered, let center = poster else { return }
        PauseRequest.registered = true
        let observer = Unmanaged.passUnretained(PauseRequest.shared).toOpaque()
        for name in [pauseRequestName, resumeRequestName] {
            CFNotificationCenterAddObserver(
                center, observer,
                // The callback cannot capture -- not the handler, not even the
                // name it was registered for -- so which button was pressed is read
                // back off the notification's own name, spelled out here rather
                // than referenced.
                { _, _, delivered, _, _ in
                    let which = (delivered?.rawValue as String?) ?? ""
                    DispatchQueue.main.async {
                        PauseRequest.handler?(which == "com.example.offlinevoiceassistant.pause")
                    }
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private final class PauseRequest {
        static let shared = PauseRequest()
        static var handler: ((Bool) -> Void)?
        static var registered = false
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
