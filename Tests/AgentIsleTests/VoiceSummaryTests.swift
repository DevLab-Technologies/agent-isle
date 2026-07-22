import XCTest
@testable import AgentIsle

/// Contracts for the on-device voice line composition. `VoiceSummary` is pure, so we assert
/// the spoken text directly — this locks in the phrasing per event kind and style, and the
/// stable per-agent voice mapping that makes "distinct voice per agent" survive relaunches.
final class VoiceSummaryTests: XCTestCase {

    private func session(_ agent: AgentKind = .claude,
                         title: String = "fix auth bug",
                         message: String = "Updated middleware.ts (+3 -1)",
                         status: SessionStatus = .done,
                         permission: PermissionRequest? = nil,
                         question: AgentQuestion? = nil) -> AgentSession {
        AgentSession(agent: agent, title: title, terminal: "iTerm",
                     lastMessage: message, status: status,
                     permission: permission, question: question)
    }

    func testDoneStylesReadDifferently() {
        let s = session()
        XCTAssertEqual(VoiceSummary.line(for: s, kind: .done, style: .terse), "Claude done.")
        XCTAssertEqual(VoiceSummary.line(for: s, kind: .done, style: .standard),
                       "Claude finished: fix auth bug.")
        XCTAssertEqual(VoiceSummary.line(for: s, kind: .done, style: .detailed),
                       "Claude finished: fix auth bug. Updated middleware.ts (+3 -1).")
        XCTAssertTrue(VoiceSummary.line(for: s, kind: .done, style: .playful)
                        .contains("wrapped up"))
    }

    func testDoneWithoutTitleStillSpeaks() {
        let s = session(title: "")
        XCTAssertEqual(VoiceSummary.line(for: s, kind: .done, style: .standard), "Claude finished.")
    }

    func testPermissionNamesToolAndFile() {
        let perm = PermissionRequest(toolName: "Edit", filePath: "src/auth/middleware.ts")
        let s = session(status: .waiting, permission: perm)
        let line = VoiceSummary.line(for: s, kind: .permission, style: .standard)
        XCTAssertEqual(line, "Claude wants permission to edit middleware.ts.")
    }

    func testPermissionWithoutFileFallsBackToTool() {
        let perm = PermissionRequest(toolName: "Bash", filePath: nil)
        let s = session(status: .waiting, permission: perm)
        let line = VoiceSummary.line(for: s, kind: .permission, style: .standard)
        XCTAssertEqual(line, "Claude wants permission to run Bash.")
    }

    func testQuestionUsesAgentNameAndSummary() {
        let q = AgentQuestion(prompt: "Which deployment target?",
                              options: ["Production", "Staging"])
        let s = session(status: .asking, question: q)
        let line = VoiceSummary.line(for: s, kind: .question, style: .standard)
        XCTAssertTrue(line.hasPrefix("Claude has a question."))
    }

    func testSpokenCollapsesWhitespaceAndClipsAtWordBoundary() {
        XCTAssertEqual(VoiceSummary.spoken("  hello   world \n"), "hello world")
        let long = String(repeating: "word ", count: 100)
        let clipped = VoiceSummary.spoken(long, limit: 20)
        XCTAssertLessThanOrEqual(clipped.count, 21)   // limit + the ellipsis
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testStableIndexIsDeterministicAndInRange() {
        for agent in AgentKind.allCases {
            let a = stableIndex(agent.rawValue, count: 8)
            let b = stableIndex(agent.rawValue, count: 8)
            XCTAssertEqual(a, b, "same input must map to the same index")
            XCTAssertTrue((0..<8).contains(a))
        }
        XCTAssertEqual(stableIndex("anything", count: 0), 0, "zero count must not divide by zero")
    }

    func testShouldAnnounceHonorsToggles() {
        var config = VoiceConfig()
        config.announceOnDone = true
        config.announceOnAttention = false
        XCTAssertTrue(config.shouldAnnounce(.done))
        XCTAssertFalse(config.shouldAnnounce(.permission))
        XCTAssertFalse(config.shouldAnnounce(.question))
        config.announceOnAttention = true
        XCTAssertTrue(config.shouldAnnounce(.plan))
    }
}
