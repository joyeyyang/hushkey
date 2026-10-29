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

    /// Where a pasted text sits in a field that now holds it, as a range in
    /// UTF-16 units.
    ///
    /// This is the search a spoken edit needs: the app pasted something, the
    /// user then said "change that", and the replacement has to go exactly
    /// where the original is. The field's own text is the only handle left, and
    /// the field may well hold the same text more than once — so which
    /// occurrence is replaced matters, and getting it wrong edits a sentence
    /// the user did not mean.
    ///
    /// The rule is the LAST occurrence that ends at or before the caret. The
    /// caret is what makes it "the one that was pasted": the app pasted at the
    /// caret, so what it left is the last text ending there. Searching
    /// backwards from the caret picks that one over an earlier copy, and
    /// confining the search to the caret leaves out text the user has since
    /// typed past.
    ///
    /// Offsets are UTF-16 units, which is what an Accessibility text range
    /// counts in, so the search works on `NSString` and not `String`.
    ///
    /// Returns nil when the text is not there — the caller keeps the result on
    /// the clipboard and tells the user, which is the harmless outcome.
    public static func insertionRange(of expected: String, in text: NSString, before limit: Int) -> NSRange? {
        guard !expected.isEmpty, text.length > 0 else { return nil }
        let bounded = min(text.length, max(0, limit))
        guard bounded > 0 else { return nil }
        let found = text.range(of: expected, options: .backwards, range: NSRange(location: 0, length: bounded))
        return found.location == NSNotFound ? nil : found
    }
}
