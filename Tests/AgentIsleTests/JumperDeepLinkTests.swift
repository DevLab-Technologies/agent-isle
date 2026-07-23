import XCTest
@testable import AgentIsle

/// Contracts for Jumper's Claude Desktop deep-link building (pure logic — no app launch).
final class JumperDeepLinkTests: XCTestCase {

    private func session(transcriptURL: URL?) -> AgentSession {
        AgentSession(agent: .claude, title: "fix auth", terminal: "Desktop",
                     lastMessage: "", status: .working, transcriptURL: transcriptURL)
    }

    func testResumeURLUsesTranscriptSessionUUID() {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let url = URL(fileURLWithPath: "/Users/me/.claude/projects/slug/\(uuid).jsonl")
        XCTAssertEqual(Jumper.claudeResumeURL(for: session(transcriptURL: url))?.absoluteString,
                       "claude://resume?session=\(uuid)")
    }

    func testResumeURLNilWithoutTranscript() {
        XCTAssertNil(Jumper.claudeResumeURL(for: session(transcriptURL: nil)))
    }

    func testResumeURLNilWhenTranscriptStemIsNotAUUID() {
        // Grok/Copilot-style histories aren't UUID-named CLI transcripts, so there's no
        // Claude Desktop session to resume — don't hand it a bogus id.
        let url = URL(fileURLWithPath: "/Users/me/.grok/sessions/history.json")
        XCTAssertNil(Jumper.claudeResumeURL(for: session(transcriptURL: url)))
    }
}
