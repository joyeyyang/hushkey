import Foundation

/// The one thing the app and the keyboard share: the text to type next.
///
/// A keyboard extension cannot run a 100 MB recogniser (its memory budget is a
/// fraction of the app's), so the split is: the app records and transcribes, the
/// keyboard only inserts. The handoff goes through the App Group so both sides
/// see the same "latest" without any IPC beyond a defaults read.
enum SharedStore {
    static let appGroup = "group.com.example.offlinevoiceassistant"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Container for models and the handoff, so it survives both processes.
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var modelsDir: URL { container.appendingPathComponent("models", isDirectory: true) }

    struct Handoff: Codable {
        var text: String
        var createdAt: Double
        var consumed: Bool
    }

    private static let key = "handoff"

    static func put(_ text: String) {
        let h = Handoff(text: text, createdAt: Date().timeIntervalSince1970, consumed: false)
        if let data = try? JSONEncoder().encode(h) {
            defaults?.set(data, forKey: key)
        }
    }

    static func latest() -> Handoff? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Handoff.self, from: data)
    }

    /// The text this keyboard has not typed yet, if any.
    static func pending() -> Handoff? {
        guard let h = latest(), !h.consumed, !h.text.isEmpty else { return nil }
        return h
    }

    static func markConsumed(_ h: Handoff) {
        var copy = h
        copy.consumed = true
        if let data = try? JSONEncoder().encode(copy) {
            defaults?.set(data, forKey: key)
        }
    }

    /// Whether the recogniser is installed. The app downloads or imports it; the
    /// keyboard only reads the answer to show a hint.
    static var hasModels: Bool {
        FileManager.default.fileExists(
            atPath: modelsDir.appendingPathComponent("asr/dolphin/model.int8.onnx").path
        )
    }
}
