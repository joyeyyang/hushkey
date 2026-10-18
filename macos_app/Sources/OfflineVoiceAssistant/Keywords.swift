import Foundation

/// Manages user-defined keywords (names, project codes, etc.) stored in UserDefaults.
/// Injected into the LLM refine prompt as hints to improve recognition accuracy.
final class Keywords {
    private let defaults = UserDefaults.standard
    private let key = "offlineVoiceAssistant.keywords"

    var all: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    func add(_ kw: String) {
        let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all
        if !list.contains(trimmed) {
            list.append(trimmed)
            all = list
        }
    }

    func remove(_ kw: String) {
        all = all.filter { $0 != kw }
    }

    /// Builds a hint string for the LLM refine prompt.
    /// Injected after the main system instruction so the model treats these as
    /// high-priority vocabulary (names, project codes, acronyms, etc.).
    func hintString() -> String {
        let list = all
        if list.isEmpty { return "" }
        // Bilingual hint so the model picks it up regardless of transcript language.
        return "【專有名詞提示 / Preferred terms】請優先使用以下詞彙，不要改寫或拼錯：" +
               list.joined(separator: "、") + "。"
    }
}
