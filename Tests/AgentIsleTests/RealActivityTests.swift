import XCTest
@testable import AgentIsle

/// Contracts for `TranscriptReader.lastRealActivity`: an idle session keeps appending
/// bookkeeping to its transcript (artifact ledgers, away summaries, titles…), so the file's
/// mtime can't tell "working" from "idle". Only real activity entries may move the clock.
final class RealActivityTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-activity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private let old = "2026-11-08T17:37:12.345Z"
    private let fresh = "2026-11-09T09:58:38.120Z"

    private let ledger = #"{"type":"artifact-autoreact-ledger","v":1,"sessionId":"s","artifacts":{"a":{"savedAt":1762682318000,"everBaselined":true}}}"#

    private func assistant(_ ts: String) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"done"}]}}"#
    }

    private func system(_ subtype: String, _ ts: String) -> String {
        #"{"type":"system","subtype":"\#(subtype)","timestamp":"\#(ts)","content":"x"}"#
    }

    private func hook(_ event: String, _ ts: String) -> String {
        #"{"type":"attachment","timestamp":"\#(ts)","attachment":{"type":"hook_success","hookEvent":"\#(event)"}}"#
    }

    private func date(_ s: String) -> Date? { TranscriptReader.parseISO(s) }

    func testLedgerWritesAfterOldMessageDontCount() throws {
        let url = try writeLines([assistant(old), ledger, ledger, ledger])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(old))
    }

    func testFreshAssistantMessageCounts() throws {
        let url = try writeLines([assistant(old), ledger, assistant(fresh)])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(fresh))
    }

    func testTailOfOnlyBookkeepingIsNil() throws {
        let url = try writeLines([ledger, #"{"type":"custom-title","customTitle":"t"}"#, ledger])
        XCTAssertNil(TranscriptReader.lastRealActivity(in: url))
    }

    func testIdleSystemEntriesDontCount() throws {
        let url = try writeLines([
            assistant(old),
            system("stop_hook_summary", fresh), system("turn_duration", fresh),
            system("away_summary", fresh), system("bridge_status", fresh),
            system("informational", fresh),
        ])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(old))
    }

    func testOtherSystemEntriesCount() throws {
        // Denylist: an unknown or genuinely active system entry still counts as activity.
        let url = try writeLines([assistant(old), system("local_command", fresh)])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(fresh))
    }

    func testSessionStartHookOnResumeDoesntCount() throws {
        let url = try writeLines([assistant(old), hook("SessionStart", fresh)])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(old))
    }

    func testToolHookOutputCounts() throws {
        let url = try writeLines([assistant(old), hook("PostToolUse", fresh)])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url), date(fresh))
    }

    func testTimestampWithoutFractionalSeconds() throws {
        let url = try writeLines([assistant("2026-11-09T09:58:38Z")])
        XCTAssertEqual(TranscriptReader.lastRealActivity(in: url),
                       Date(timeIntervalSince1970: 1_794_218_318))
    }

    private func writeLines(_ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
