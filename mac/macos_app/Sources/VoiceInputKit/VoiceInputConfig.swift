import Foundation

/// Everything the engine needs to know that is not baked into the model files.
///
/// The point of this type is that a caller can describe a complete dictation
/// setup — where the models live, which words are proper nouns, how hard the
/// cleanup pass should work, and which model files to use — and then forget
/// about it. Nothing here is UI state; the app keeps its own settings and maps
/// them onto this.
public struct VoiceInputConfig {

    /// Root of the model tree, the same directory `Core_Initialize` is handed.
    /// `asr/`, `llm/` and `embedding/` live directly under it.
    public var modelsDirectory: URL

    /// The user's proper-noun list. Injected into the refine prompt as a hint.
    public var keywords: [String]

    /// How many model passes the cleanup should run: 0 = let the engine decide
    /// by transcript length, 1 = condense once, 2 = understand then condense.
    /// Passed straight through to the engine, which owns the rule.
    public var refineStages: UInt32

    /// The register the cleanup writes in: "casual", "normal" (the default) or
    /// "formal". The engine treats anything else as "normal", so a stale value
    /// costs the register and never the dictation.
    ///
    /// A string rather than an enum for the same reason `translateTarget` is
    /// one: the value is a settings key that the app, the command-line tool and
    /// the core all have to agree on, and an enum here would make the three
    /// copies the thing that drifts.
    ///
    /// It only applies to the cleanup (`refineStages`); translate and spoken
    /// edit have their own jobs and do not take a register.
    public var refineTone: String

    /// What to do about the language of the finished line:
    ///   - "auto" — no separate translate pass; the refine prompt decides.
    ///   - "off"  — no translate pass either, but see `polishEnabled`.
    ///   - "en" / "zh" — run a dedicated translate pass AFTER the refine pass.
    ///
    /// Translation is kept separate from refine on purpose: asking one prompt to
    /// both clean and translate produced half-translated drafts, and refine must
    /// never change the language while translate must.
    public var translateTarget: String

    /// Bare filename of the LLM inside `models/llm/`, or nil for the engine's
    /// own default. The engine rejects anything containing "/" or ".." and
    /// joins the name onto the models directory itself, so a bare name is the
    /// only thing that can travel.
    public var llmModel: String?

    /// Whether a session also captures what the Mac is playing.
    ///
    /// Off by default: it is a meeting feature, it needs a separate permission
    /// (System Audio Recording), and with the Mac on loudspeakers the microphone
    /// hears the far end too, so a phrase can arrive twice.
    public var captureSystemAudio: Bool
    /// The `ovc-llm-worker` executable, when it does not sit beside the caller.
    ///
    /// The engine looks next to its own executable by default, which is right for
    /// the app bundle; a command-line tool or a different host app has to say
    /// where the worker is.
    public var workerExecutable: URL?

    /// When false, the transcript is returned verbatim (script-normalised) and
    /// no LLM pass runs at all. This is the "raw mode" toggle; it exists as a
    /// config value rather than a magic translate target so that "no cleanup"
    /// and "no translation" stay independent choices.
    public var polishEnabled: Bool

    public init(
        modelsDirectory: URL = VoiceInputConfig.defaultModelsDirectory(),
        keywords: [String] = [],
        refineStages: UInt32 = 0,
        refineTone: String = "normal",
        translateTarget: String = "auto",
        llmModel: String? = nil,
        workerExecutable: URL? = nil,
        captureSystemAudio: Bool = false,
        polishEnabled: Bool = true
    ) {
        self.modelsDirectory = modelsDirectory
        self.keywords = keywords
        self.refineStages = refineStages
        self.refineTone = refineTone
        self.translateTarget = translateTarget
        self.llmModel = llmModel
        self.workerExecutable = workerExecutable
        self.captureSystemAudio = captureSystemAudio
        self.polishEnabled = polishEnabled
    }

    /// The standard model location, mirroring exactly what the app itself
    /// resolves (`OVC_MODELS`, then `OVC_DATA_DIR`, then Application Support) so
    /// that a caller of this kit and the running app read the same tree.
    public static func defaultModelsDirectory() -> URL {
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
}

/// One utterance, exactly what the ASR returned for one VAD segment.
///
/// `index` is 1-based and assigned once when the segment arrives — the engine
/// never renumbers within a session, so it is safe to use as a stable id.
public struct Utterance: Codable, Sendable, Equatable, Identifiable {

    /// Which audio route the speech came from. Only the microphone route is
    /// produced by this kit today; the case exists so a meeting transcript built
    /// elsewhere can round-trip through here unchanged.
    public enum Source: String, Codable, Sendable {
        case microphone
        case systemAudio
    }

    public var index: Int
    public var source: Source
    /// Seconds from the start of the session.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public var id: Int { index }

    public var duration: TimeInterval { max(0, end - start) }

    public init(index: Int, source: Source, start: TimeInterval, end: TimeInterval, text: String) {
        self.index = index
        self.source = source
        self.start = start
        self.end = end
        self.text = text
    }
}

/// What a finished dictation produced.
///
/// Both texts are kept: `raw` is what the speaker actually said, `refined` is
/// what the model made of it. Callers that paste use `refined`; callers that
/// export a transcript keep both so a bad cleanup can always be compared
/// against the source.
public struct VoiceInputResult {
    /// The verbatim transcript.
    public let raw: String
    /// After keyword retrieval and the AI cleanup pass.
    public let refined: String
    /// Whatever the ASR produced, in engine order.
    public let segments: [Utterance]
    /// Seconds of audio that were actually decoded.
    ///
    /// The container's own duration is not this: a file can claim a length it
    /// does not have, and the number the user sees has to be the audio that was
    /// heard.
    public let duration: TimeInterval

    public init(raw: String, refined: String, segments: [Utterance], duration: TimeInterval = 0) {
        self.raw = raw
        self.refined = refined
        self.segments = segments
        self.duration = duration
    }
}

/// Every failure this kit reports, in one type.
///
/// `.core` is the raw C ABI status; the rest are conditions the kit detects
/// itself (a missing file, a denied microphone) and which the core would only
/// report as a generic inference error.
public enum VoiceInputError: Error, CustomStringConvertible {
    /// A non-zero `OvcStatus` plus the message that accompanied it.
    case core(Int32, String)
    /// The configuration cannot be used as given.
    case badConfig(String)
    case microphoneDenied
    case fileUnreadable(String)
    case unsupportedFormat(String)
    case noAudioTrack
    case emptyAudio
    case decoderUnavailable(String)
    case notStarted
    case cancelled

    public var description: String {
        switch self {
        case let .core(code, message):
            return "core error \(code): \(message.isEmpty ? "(no message)" : message)"
        case let .badConfig(why): return "invalid config: \(why)"
        case .microphoneDenied: return "microphone access was not granted"
        case let .fileUnreadable(name): return "cannot read “\(name)”"
        case let .unsupportedFormat(why): return "cannot decode this audio format: \(why)"
        case .noAudioTrack: return "the file has no audio track"
        case .emptyAudio: return "the audio is empty or has zero length"
        case let .decoderUnavailable(why): return "audio decoder unavailable: \(why)"
        case .notStarted: return "the session was never started"
        case .cancelled: return "cancelled"
        }
    }
}

/// The user's keyword list, on disk.
///
/// Persistence lives here rather than in `VoiceInputConfig` because the list is
/// durable user state, not per-run configuration. The key matches the app's own
/// (`offlineVoiceAssistant.keywords`) so a list edited by the CLI shows up in
/// the app and vice versa — as long as both run under the same defaults domain.
public enum KeywordStore {

    public static let defaultsKey = "offlineVoiceAssistant.keywords"

    public static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    public static func save(_ keywords: [String]) {
        UserDefaults.standard.set(keywords, forKey: defaultsKey)
    }

    /// Appends a trimmed, non-empty, not-already-present term.
    @discardableResult
    public static func add(_ keyword: String) -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return load() }
        var list = load()
        if !list.contains(trimmed) {
            list.append(trimmed)
            save(list)
        }
        return list
    }

    @discardableResult
    public static func remove(_ keyword: String) -> [String] {
        let list = load().filter { $0 != keyword }
        save(list)
        return list
    }

    /// Builds the hint block injected into the refine prompt.
    ///
    /// Bilingual on purpose: the ASR can return either script and the prompt
    /// must read as high-priority vocabulary regardless. Empty for an empty
    /// list, which is what lets the engine's prompt fall back to its default.
    public static func hintString(_ keywords: [String]) -> String {
        let list = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if list.isEmpty { return "" }
        return "【專有名詞提示 / Preferred terms】請優先使用以下詞彙，不要改寫或拼錯：" +
               list.joined(separator: "、") + "。"
    }
}
