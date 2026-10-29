import XCTest
@testable import VoiceInputKit

/// The gate that decides whether a spoken line is an EDIT or something to paste.
///
/// The cost of getting it wrong is written on the predicate: a false positive
/// applies the user's words to whatever came before instead of inserting them,
/// and a false negative loses the edit (the refine prompt may still apply it,
/// so it is the cheap mistake).
final class VoiceEditInstructionTests: XCTestCase {

    /// The edits the core can carry out, and which therefore have to reach it.
    func testAcceptsTheInstructionsTheCoreCanCarryOut() {
        let accepted = [
            "把第二點改成禮拜五",
            "第三句刪掉",
            "把最後一句改短一點",
            "delete the second one",
            // The content form: the core resolves a named word as the target.
            "把地點改成三樓會議室",
            "把小林改成大衛",
            "把三點改成四點",
            // A verb that carries what it does, with no 把 in front of it.
            "第二句改短一點",
            "第二段改短",
        ]
        for text in accepted {
            XCTAssertTrue(isVoiceEditInstruction(text), "should be an edit: \(text)")
        }
    }

    /// The ordinary sentences that must NOT become edits. Each one names
    /// something and carries a verb-ish word, and each one is a thing a person
    /// says while dictating.
    func testRejectsOrdinarySentences() {
        let rejected = [
            "顏色改成藍色",
            "我把檔案刪掉了",
            "這個會議改成線上開",
            "我用英文寫了一封信",
            "第一點要改善",
            "最後一段需要修改",
        ]
        for text in rejected {
            XCTAssertFalse(isVoiceEditInstruction(text), "should not be an edit: \(text)")
        }
    }

    /// A sentence with no verb at all is text, whatever else it contains.
    func testRejectsTextWithNoEditVerb() {
        let rejected = [
            "明天下午三點跟小林開會",
            "討論第四季時程",
            "地點還沒確定",
            "第二點是關於預算",
        ]
        for text in rejected {
            XCTAssertFalse(isVoiceEditInstruction(text), "should not be an edit: \(text)")
        }
    }

    /// Nothing at all is not an edit.
    func testRejectsEmptyText() {
        XCTAssertFalse(isVoiceEditInstruction(""))
        XCTAssertFalse(isVoiceEditInstruction("   "))
    }
}
