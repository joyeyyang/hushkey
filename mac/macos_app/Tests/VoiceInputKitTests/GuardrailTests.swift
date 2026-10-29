import XCTest
@testable import VoiceInputKit

/// The guardrail as the Mac reaches it: `Text.sanityCheck` → `LLM_CheckOutput`.
///
/// The rules themselves are tested in Rust (`rust/core_engine/src/guardrail.rs`)
/// and through the C ABI (`examples/guardrail_probe.rs`). What is checked here is
/// the seam the app actually uses -- that the wrapper passes the mode and the
/// tone through, reads an empty reason as "usable", and fails CLOSED when the
/// call itself cannot run.
///
/// The fail-closed half matters more than it looks: `sanityCheck` is on the path
/// that decides whether the model's answer or the transcript gets pasted, and a
/// wrapper that treated "could not check" as "fine" would put a 2B model's remark
/// about the instructions into somebody's email.
final class GuardrailTests: XCTestCase {

    private let draft = "嗯那個明天下午三點跟小林開會，討論第四季時程，地點還沒確定"
    private let faithful = "明天下午三點與小林開會，討論第四季時程，地點尚未確定"

    func testAFaithfulCleanupIsUsable() {
        let verdict = Text.sanityCheck(faithful, comparedTo: draft)
        XCTAssertTrue(verdict.ok, verdict.reason)
        XCTAssertEqual(verdict.reason, "ok")
    }

    /// The failure the guard exists for: the model answered the prompt.
    func testAnsweringTheInstructionsIsRejectedWithAReason() {
        let verdict = Text.sanityCheck("以下是整理後的版本：明天下午三點開會", comparedTo: draft)
        XCTAssertFalse(verdict.ok)
        XCTAssertTrue(verdict.reason.contains("meta phrasing"), verdict.reason)
        // The reason is for the log; the caller's fallback is the transcript.
        XCTAssertFalse(verdict.reason.isEmpty)
    }

    /// `mode: "edit"` may delete lines -- that is what half the instructions ask
    /// for -- so the cleanup's length floor must not apply to it.
    ///
    /// Note what this does NOT claim: the cleanup path has no line-count rule
    /// either. Which lines survive is the numbering parser's business
    /// (`llm::check_edited_shape`), because only it knows the numbers; the
    /// guard's job is the shape a remark has. A two-of-three answer therefore
    /// passes both modes, and an edit is only refused when it is not text at all.
    func testAnEditMayDeleteLines() {
        let three = "明天下午三點跟小林開會\n討論第四季時程\n地點還沒確定"
        let two = "明天下午三點跟小林開會\n地點還沒確定"
        XCTAssertTrue(Text.sanityCheck(two, comparedTo: three, mode: "edit").ok)
        // The same answer with the model talking about itself is refused.
        XCTAssertFalse(
            Text.sanityCheck("以下是修改後的版本：\n" + two, comparedTo: three, mode: "edit").ok
        )
    }

    /// A register the core does not know is "normal", not an error: a settings
    /// value from an older build must not cost the user their sentence.
    func testAnUnknownToneIsNormal() {
        let verdict = Text.sanityCheck(faithful, comparedTo: draft, tone: "正式")
        XCTAssertTrue(verdict.ok, verdict.reason)
    }

    /// 正式 forbids the casual particles; 一般 does not, because its measured
    /// answers are the baseline and rejecting them would change behaviour that
    /// was already accepted.
    func testOnlyFormalRejectsCasualParticles() {
        let raw = "明天下午三點開會喔，記得帶合約啦"
        let refined = "明天下午三點開會喔，請記得攜帶合約啦"
        XCTAssertTrue(Text.sanityCheck(refined, comparedTo: raw).ok)
        XCTAssertFalse(Text.sanityCheck(refined, comparedTo: raw, tone: "formal").ok)
    }

    /// No model, no audio, no initialisation: the check is arithmetic, so it can
    /// run before `Core_Initialize` and costs microseconds. This is the property
    /// that keeps it off the latency budget -- if it ever grew a model call, this
    /// test would start failing for a reason nobody would guess.
    func testTheCheckNeedsNoModelAndIsCheap() {
        let start = Date()
        for _ in 0..<100 {
            XCTAssertTrue(Text.sanityCheck(faithful, comparedTo: draft).ok)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.1, "100 checks took \(elapsed)s; the guard is supposed to be arithmetic")
    }
}
