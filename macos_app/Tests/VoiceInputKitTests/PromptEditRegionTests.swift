import XCTest
@testable import VoiceInputKit

/// The region half of 修改提示詞: which line the instruction is about, and the
/// promise that the instruction is not pasted into the draft.
///
/// The core does the locating (`locate_edit_target`), so what is checked here is
/// the only thing this layer owns: the string handed to the core names the line
/// the user picked, and the user's own words survive it byte for byte.
final class PromptEditRegionTests: XCTestCase {

    /// 整段 must not touch the instruction at all.
    func testWholeLeavesTheInstructionAlone() {
        XCTAssertEqual(PromptEditRegion.whole.instruction("改短一點"), "改短一點")
        XCTAssertEqual(PromptEditRegion.whole.instruction("  把第二點改成禮拜五  "),
                       "把第二點改成禮拜五")
    }

    /// A line region names the line the way the core reads a position: 第 + a
    /// number + 點. The core's digit branch accepts an Arabic digit there, so
    /// "第2點" and "第二點" reach the same line.
    func testLinePrefixesThePositionTheCoreResolves() {
        XCTAssertEqual(PromptEditRegion.line(2).instruction("改成禮拜五"), "第2點改成禮拜五")
        XCTAssertEqual(PromptEditRegion.line(3).instruction("改短一點"), "第3點改短一點")
        XCTAssertEqual(PromptEditRegion.line(11).instruction("刪掉"), "第11點刪掉")
    }

    /// A number the picker cannot have produced (0 or negative) still names a
    /// real line: clamping here is what keeps "第0點" out of the prompt, where
    /// the core would find no position and fall back to the whole draft.
    func testLineClampsToTheFirstLine() {
        XCTAssertEqual(PromptEditRegion.line(0).instruction("改短一點"), "第1點改短一點")
        XCTAssertEqual(PromptEditRegion.line(-4).instruction("改短一點"), "第1點改短一點")
    }

    /// The instruction is the user's. Only a position may be added in front of
    /// it -- nothing is reworded, and nothing is appended.
    func testTheInstructionIsNeverRewritten() {
        let typed = "把「地點」改成三樓會議室"
        let sent = PromptEditRegion.line(3).instruction(typed)
        XCTAssertTrue(sent.hasSuffix(typed), "the user's words must survive verbatim: \(sent)")
        XCTAssertEqual(sent.count, typed.count + "第3點".count)
    }

    /// The region is NOT folded into the draft. The draft is passed separately,
    /// and a prefix leaking into it would give the model a text that starts with
    /// an instruction -- the failure `EDIT_SYSTEM`'s first-line rule exists to
    /// prevent.
    func testTheInstructionIsNotPartOfTheDraft() {
        let draft = "明天下午三點跟小林開會\n討論第四季時程\n地點還沒確定"
        let sent = PromptEditRegion.line(2).instruction("改短一點")
        XCTAssertFalse(draft.contains(sent))
        XCTAssertFalse(sent.contains(draft))
        XCTAssertEqual(PromptEditRegion.lines(of: draft).count, 3)
    }

    /// The picker's numbering has to agree with the core's `numbered_items`,
    /// or "第 3 行" in the UI is a different line from the one edited.
    func testLinesMatchTheCoresNumbering() {
        let draft = "• 先確認規格\n\n1. 再找供應商\n3、最後排時程\n"
        XCTAssertEqual(PromptEditRegion.lines(of: draft),
                       ["先確認規格", "再找供應商", "最後排時程"])
        // A spoken draft is one line, so the picker offers exactly one.
        XCTAssertEqual(PromptEditRegion.lines(of: "明天下午三點跟小林開會，討論第四季時程"),
                       ["明天下午三點跟小林開會，討論第四季時程"])
        XCTAssertEqual(PromptEditRegion.lines(of: "   \n\n"), [])
    }

    /// `--region` is what the command line and the app's picker both produce.
    func testRegionParsing() {
        XCTAssertEqual(PromptEditRegion.parse("whole"), .whole)
        XCTAssertEqual(PromptEditRegion.parse(" LINE:3 "), .line(3))
        XCTAssertEqual(PromptEditRegion.parse("selection"), .selection)
        XCTAssertNil(PromptEditRegion.parse("line:0"))
        XCTAssertNil(PromptEditRegion.parse("line:x"))
        XCTAssertNil(PromptEditRegion.parse("everywhere"))
    }
}
