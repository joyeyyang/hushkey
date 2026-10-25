import XCTest
@testable import VoiceInputKit

/// The search that decides WHERE a spoken edit lands.
///
/// The app pasted something, the user then said "change that", and the
/// replacement has to go exactly where the original is. The field's own text is
/// the only handle left, and the field may hold the same text more than once.
/// Getting the wrong occurrence is the failure that matters: the user edits
/// one sentence and a different one changes.
final class VoiceTextInsertionRangeTests: XCTestCase {

    /// The ordinary case: one occurrence, found.
    func testFindsTheTextItPasted() {
        let field = "今天開會討論第四季時程"
        let pasted = "今天開會"
        let range = VoiceText.insertionRange(of: pasted, in: field as NSString, before: (field as NSString).length)
        XCTAssertEqual(range, NSRange(location: 0, length: 4))
    }

    /// The same text twice, and the caret is after the second one. The LAST
    /// occurrence is the one that was pasted there -- the app pasted at the
    /// caret -- so that is the one an edit replaces.
    func testPicksTheLastOccurrenceBeforeTheCaret() {
        let field = "今天開會，然後今天開會"
        let pasted = "今天開會"
        let ns = field as NSString
        // The caret sits at the end, after the second occurrence.
        let range = VoiceText.insertionRange(of: pasted, in: ns, before: ns.length)
        // "今天開會" (4) + "，" (1) + "然後" (2) = 7 units before the second copy.
        XCTAssertEqual(range, NSRange(location: 7, length: 4))
    }

    /// The caret is BEFORE the second occurrence, so the second one was never
    /// pasted by this app -- it is something the user typed afterwards. The
    /// first occurrence is the one to replace.
    func testIgnoresTextAfterTheCaret() {
        let field = "今天開會，然後今天開會"
        let pasted = "今天開會"
        let ns = field as NSString
        // The caret is right after the first occurrence.
        let range = VoiceText.insertionRange(of: pasted, in: ns, before: 4)
        XCTAssertEqual(range, NSRange(location: 0, length: 4))
    }

    /// Text that is not in the field: nothing is found, and the caller keeps the
    /// result on the clipboard. A wrong match would replace something else.
    func testFindsNothingWhenTheTextIsGone() {
        let field = "使用者後來把那段字刪掉了"
        let pasted = "今天開會"
        let range = VoiceText.insertionRange(of: pasted, in: field as NSString, before: (field as NSString).length)
        XCTAssertNil(range)
    }

    /// An empty field, and a caret at the very start: there is nothing to find
    /// and nothing to look at.
    func testAnEmptyFieldFindsNothing() {
        XCTAssertNil(VoiceText.insertionRange(of: "今天開會", in: "" as NSString, before: 0))
        XCTAssertNil(VoiceText.insertionRange(of: "", in: "今天開會" as NSString, before: 4))
    }

    /// The offsets are UTF-16 units, which is what an Accessibility text range
    /// counts in. A Chinese character is one unit in UTF-16 but one Character in
    /// Swift, so a search that counted characters would land in the wrong place
    /// as soon as an emoji was in the field.
    func testTheOffsetsAreUtf16Units() {
        let field = "🙂今天開會"
        let ns = field as NSString
        let range = VoiceText.insertionRange(of: "今天開會", in: ns, before: ns.length)
        // The emoji is two UTF-16 units, so the text starts at 2.
        XCTAssertEqual(range, NSRange(location: 2, length: 4))
    }
}
