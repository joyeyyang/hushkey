import XCTest
@testable import VoiceInputKit

/// The log that turns a rejected answer into the next prompt fix.
///
/// The path is overridden with `OVC_HALLUCINATION_LOG` so a test run never
/// writes into the user's real Documents folder.
final class HallucinationLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ovc-hallucination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("OVC_HALLUCINATION_LOG",
               directory.appendingPathComponent("hallucination_log.json").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("OVC_HALLUCINATION_LOG")
        try? FileManager.default.removeItem(at: directory)
    }

    func testARejectionIsKeptWithEverythingNeededToReplayIt() throws {
        HallucinationLog.record(
            mode: "refine", tone: "formal",
            raw: "明天下午三點跟小林開會",
            refined: "以下是整理後的版本：明天下午三點開會",
            reason: "meta phrasing: 以下是"
        )
        HallucinationLog.flush()

        let entries = HallucinationLog.entries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.mode, "refine")
        XCTAssertEqual(entry.tone, "formal")
        XCTAssertEqual(entry.raw, "明天下午三點跟小林開會")
        XCTAssertEqual(entry.refined, "以下是整理後的版本：明天下午三點開會")
        XCTAssertEqual(entry.reason, "meta phrasing: 以下是")
        XCTAssertFalse(entry.timestamp.isEmpty)

        // A file a person or a script can read without this code: the whole
        // point is that the sample outlives the process that rejected it.
        let url = try XCTUnwrap(HallucinationLog.fileURL)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(Set(json[0].keys),
                       ["timestamp", "mode", "tone", "reason", "raw", "refined"])
    }

    func testTheFileKeepsTheNewestEntriesAndStopsGrowing() throws {
        for index in 0..<205 {
            HallucinationLog.record(
                mode: "edit", tone: "normal",
                raw: "draft \(index)", refined: "remark \(index)",
                reason: "meta phrasing: 以下是"
            )
        }
        HallucinationLog.flush()

        let entries = HallucinationLog.entries()
        XCTAssertEqual(entries.count, 200)
        // The newest survive: a pattern is visible in the latest failures, and
        // the oldest are the ones already acted on.
        XCTAssertEqual(entries.first?.raw, "draft 5")
        XCTAssertEqual(entries.last?.raw, "draft 204")
    }

    func testAnUnreadableFileIsTreatedAsEmptyRatherThanCrashing() throws {
        let url = try XCTUnwrap(HallucinationLog.fileURL)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(HallucinationLog.entries().isEmpty)

        HallucinationLog.record(mode: "refine", tone: "normal",
                                raw: "a", refined: "b", reason: "r")
        HallucinationLog.flush()
        XCTAssertEqual(HallucinationLog.entries().count, 1)
    }
}
