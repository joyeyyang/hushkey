import Foundation

/// The two text transforms the app still needs, now that its own copies are
/// gone.
///
/// The app used to carry private copies of these beside the kit's, which is how
/// a paste style could drift between the two. They stay a small public enum
/// rather than methods somewhere else because both are pure functions of a
/// string with nothing to configure, and both are needed on their own — the app
/// normalises text it already holds, in places that never touch the engine.
public enum VoiceText {

    /// Simplified → Traditional, using macOS's built-in ICU transform. A no-op
    /// for text without Han characters.
    public static func toTraditional(_ text: String) -> String {
        Text.toTraditional(text)
    }

    /// Housekeeping on model output before it is pasted: one newline style, plain
    /// "• " bullets instead of Markdown markers, and no bold markers.
    public static func normalizeForPaste(_ text: String) -> String {
        Text.normalizeOutput(text)
    }
}
