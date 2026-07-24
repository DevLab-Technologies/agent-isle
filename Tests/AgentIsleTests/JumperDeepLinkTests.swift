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

    // MARK: - targetBundleID (the app keystroke delivery waits to become frontmost)

    private func session(terminal: String, bundle: String?) -> AgentSession {
        AgentSession(agent: .claude, title: "t", terminal: terminal,
                     lastMessage: "", status: .working, terminalBundleID: bundle)
    }

    func testTargetBundlePrefersHookReportedBundle() {
        // The hook's exact TERM_PROGRAM bundle wins over the label lookup.
        let s = session(terminal: "VS Code", bundle: "com.microsoft.VSCodeInsiders")
        XCTAssertEqual(Jumper.targetBundleID(for: s), "com.microsoft.VSCodeInsiders")
    }

    func testTargetBundleFallsBackToLabelMap() {
        // A transcript-only session carries no bundle id, so the terminal label resolves it.
        XCTAssertEqual(Jumper.targetBundleID(for: session(terminal: "VS Code", bundle: nil)),
                       "com.microsoft.VSCode")
        XCTAssertEqual(Jumper.targetBundleID(for: session(terminal: "Ghostty", bundle: nil)),
                       "com.mitchellh.ghostty")
    }

    func testTargetBundleNilForUnknownLabel() {
        // No bundle and an unrecognized label → can't predict focus; caller settles instead.
        XCTAssertNil(Jumper.targetBundleID(for: session(terminal: "Mystery", bundle: nil)))
    }
}
