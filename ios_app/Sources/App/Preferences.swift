import Foundation

/// What to do about the language of a finished sentence.
///
/// The four values are the Mac's, with the same meanings, because a setting that
/// behaves differently on the two platforms is worse than a missing one:
///
///   - `auto` — no separate translate pass; the refine prompt decides, which in
///     practice means "answer in the language you were spoken to".
///   - `off` — same, but the setting exists to be explicit about it.
///   - `en` / `zh` — run a dedicated translate pass AFTER the cleanup.
enum TranslateMode: String, CaseIterable {
    case auto
    case off
    case en
    case zh

    /// Shown in the settings card, in the Mac's wording.
    var title: String {
        switch self {
        case .auto: return "自動"
        case .off: return "不翻譯"
        case .en: return "一律英文"
        case .zh: return "一律繁體中文"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "跟你說的語言一致，說英文就回英文。"
        case .off: return "不做翻譯，只整理。"
        case .en: return "整理完再翻成英文。"
        case .zh: return "整理完再轉成繁體中文。"
        }
    }

    /// The string the core's translate pass takes; nil means "no pass".
    var target: String? {
        switch self {
        case .en, .zh: return rawValue
        case .auto, .off: return nil
        }
    }
}

/// Preferences the Mac has a settings card for, stored where both sides can read
/// them.
///
/// The App Group defaults, not the app's own: the keyboard does not read these
/// today, but a setting that the two processes disagree about is exactly the kind
/// of bug that took a device benchmark to explain last time.
enum Preferences {

    static var translate: TranslateMode {
        get {
            guard let raw = SharedStore.defaults?.string(forKey: "translate"),
                  let mode = TranslateMode(rawValue: raw)
            else { return .auto }
            return mode
        }
        set { SharedStore.defaults?.set(newValue.rawValue, forKey: "translate") }
    }

    /// 0 = let the engine decide by transcript length, 1 = condense once,
    /// 2 = understand then condense. Same ladder as the Mac's `--refine-stages`.
    static var refineStages: Int {
        get { SharedStore.defaults?.integer(forKey: "refineStages") ?? 0 }
        set { SharedStore.defaults?.set(newValue, forKey: "refineStages") }
    }

    /// What the refine pass is actually handed.
    ///
    /// Empty on purpose when no pass will run: `auto` and `off` both mean "the
    /// refine prompt decides", and a target of "" is how the core reads that.
    static var translateTarget: String {
        translate.target ?? ""
    }
}

/// The proper-noun list.
///
/// The Mac keeps this tab and deliberately injects *nothing* from it into the
/// prompt any more (`TextPostprocess.polish`: "a name that is on the list but was
/// NOT said this time gets pulled into the sentence"). iOS keeps the list for the
/// same reason the Mac does — it is where a user checks how a name should be
/// spelled, and where the next export reads it from — and passes the same empty
/// hint so the two platforms do not diverge in what the model is told.
enum Keywords {

    private static let key = "keywords"

    static var list: [String] {
        get { SharedStore.defaults?.stringArray(forKey: key) ?? [] }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // Same term twice is not a different term; the first spelling wins.
            var seen = Set<String>()
            let unique = cleaned.filter { seen.insert($0).inserted }
            SharedStore.defaults?.set(unique, forKey: key)
        }
    }

    @discardableResult
    static func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var current = list
        guard !current.contains(trimmed) else { return false }
        current.append(trimmed)
        list = current
        return true
    }

    static func remove(_ term: String) {
        list = list.filter { $0 != term }
    }

    static func clear() {
        SharedStore.defaults?.removeObject(forKey: key)
    }
}
