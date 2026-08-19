import XCTest
@testable import AgentIsle

/// Claude Code injects machine-written turns on the *user* side of a transcript. Rendered
/// verbatim they filled the chat panel with XML, so these pin what gets dropped, what gets
/// condensed to a notice, and — most importantly — what must survive untouched.
final class ChatNoiseTests: XCTestCase {

    func testPlainPromptIsUntouched() {
        XCTAssertEqual(ChatNoise.sanitize("  fix the auth bug  "),
                       .message("fix the auth bug"))
    }

    func testSystemReminderIsDropped() {
        let raw = "<system-reminder>Contents of CLAUDE.md ...</system-reminder>"
        XCTAssertEqual(ChatNoise.sanitize(raw), .drop)
    }

    func testSystemReminderIsStrippedFromARealPrompt() {
        let raw = "ship it\n<system-reminder>background context</system-reminder>"
        XCTAssertEqual(ChatNoise.sanitize(raw), .message("ship it"))
    }

    func testTaskNotificationBecomesItsSummary() {
        let raw = """
        <task-notification>
        <task-id>bue3zxdhf</task-id>
        <tool-use-id>toolu_01D4biyP4g873shpPa5DMj9E</tool-use-id>
        <output-file>/private/tmp/claude-501/tasks/bue3zxdhf.output</output-file>
        <status>completed</status>
        <summary>Background command "gh pr checks 54" completed (exit code 0)</summary>
        </task-notification>
        """
        XCTAssertEqual(ChatNoise.sanitize(raw),
                       .notice(#"Background task: Background command "gh pr checks 54" completed (exit code 0)"#))
    }

    func testTaskNotificationWithoutASummaryStillReadsAsOneLine() {
        let raw = "<task-notification><status>completed</status></task-notification>"
        XCTAssertEqual(ChatNoise.sanitize(raw), .notice("Background task finished"))
    }

    func testSlashCommandCollapsesToItsName() {
        let raw = """
        <command-name>/design</command-name>
        <command-message>design</command-message>
        <command-args></command-args>
        <local-command-stdout>Usage: /design consent</local-command-stdout>
        """
        XCTAssertEqual(ChatNoise.sanitize(raw), .notice("Ran /design"))
    }

    /// A prompt typed alongside a command envelope is still the user talking.
    func testRealTextWinsOverANotice() {
        let raw = "<system-reminder>noise</system-reminder>\nnow merge it"
        XCTAssertEqual(ChatNoise.sanitize(raw), .message("now merge it"))
    }

    /// Mentioning a tag without closing it must not eat the prompt.
    func testUnclosedTagIsNotTreatedAsAnEnvelope() {
        let raw = "why does <system-reminder> show up in my chat?"
        XCTAssertEqual(ChatNoise.sanitize(raw),
                       .message("why does <system-reminder> show up in my chat?"))
    }

    func testNoticesAreClampedToOneLine() {
        let body = String(repeating: "long summary text ", count: 20)
        guard case .notice(let n) = ChatNoise.sanitize("<task-notification><summary>\(body)</summary></task-notification>") else {
            return XCTFail("expected a notice")
        }
        XCTAssertLessThanOrEqual(n.count, 140)
        XCTAssertFalse(n.contains("\n"))
    }
}
