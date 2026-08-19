import XCTest
@testable import AgentIsle

/// The Accessibility prompt is the only thing in Agent Isle that can open System Settings, and
/// macOS reopens it on *every* prompting trust check while untrusted. These lock in the rule
/// that keeps that from turning into a nag: ask once, then never again on repeat attempts, and
/// only forget the ask once real trust is observed.
///
/// `decide` picks the outcome and `record` applies it to the remembered flag; together they
/// are everything `check()` does apart from the two system calls, so the bookkeeping is
/// covered here without prompting the machine running the tests.
@MainActor
final class AccessibilityPermissionTests: XCTestCase {

    func testTrustedNeverPrompts() {
        XCTAssertEqual(AccessibilityPermission.decide(isTrusted: true, alreadyAsked: false),
                       .trusted)
        XCTAssertEqual(AccessibilityPermission.decide(isTrusted: true, alreadyAsked: true),
                       .trusted)
    }

    func testFirstUntrustedAttemptPrompts() {
        XCTAssertEqual(AccessibilityPermission.decide(isTrusted: false, alreadyAsked: false),
                       .prompted)
    }

    /// The reported bug: a grant that reads as enabled but doesn't apply to this copy keeps
    /// trust false forever, so every later send must stay silent instead of reopening Settings.
    func testRepeatUntrustedAttemptsDoNotPrompt() {
        XCTAssertEqual(AccessibilityPermission.decide(isTrusted: false, alreadyAsked: true),
                       .alreadyAsked)
    }

    /// The first untrusted attempt prompts *and* records the ask — without the record, every
    /// later send would prompt again and the nag would be back.
    func testFirstAttemptRecordsTheAsk() {
        var asked = false
        let prompt = AccessibilityPermission.record(.prompted, alreadyAsked: &asked)
        XCTAssertTrue(prompt)
        XCTAssertTrue(asked)
    }

    func testLaterAttemptsNeitherPromptNorForgetTheAsk() {
        var asked = true
        let prompt = AccessibilityPermission.record(.alreadyAsked, alreadyAsked: &asked)
        XCTAssertFalse(prompt)
        XCTAssertTrue(asked)
    }

    /// Observing real trust clears the ask, so a later genuine loss of the grant (app update,
    /// re-signing) still gets its one prompt.
    func testTrustForgetsTheAsk() {
        var asked = true
        let prompt = AccessibilityPermission.record(.trusted, alreadyAsked: &asked)
        XCTAssertFalse(prompt)
        XCTAssertFalse(asked)
    }

    /// Two untrusted attempts in a row prompt exactly once.
    func testAskOnceAcrossRepeatedAttempts() {
        var asked = false
        var prompts = 0
        for _ in 0..<5 {
            let outcome = AccessibilityPermission.decide(isTrusted: false, alreadyAsked: asked)
            if AccessibilityPermission.record(outcome, alreadyAsked: &asked) { prompts += 1 }
        }
        XCTAssertEqual(prompts, 1)
    }

    /// Neither message may over-claim: the first must not promise a prompt window (macOS shows
    /// none when the app is already listed), and the second must not assert a stale grant as
    /// fact — the user may simply not have finished granting it.
    func testErrorMessagesDoNotOverClaim() {
        let first = MessageSender.SendError.accessibilityDenied(staleGrantSuspected: false).userMessage
        let again = MessageSender.SendError.accessibilityDenied(staleGrantSuspected: true).userMessage
        XCTAssertNotEqual(first, again)
        XCTAssertFalse(first.localizedCaseInsensitiveContains("just opened"))
        XCTAssertFalse(again.localizedCaseInsensitiveContains("still isn't active"))
        // The remove-and-re-add path is offered conditionally, not as a diagnosis.
        XCTAssertTrue(again.localizedCaseInsensitiveContains("if it already looks enabled"))
        XCTAssertTrue(again.localizedCaseInsensitiveContains("remove"))
    }

    /// Trust observed mid-streak resets it, so a later genuine loss of the grant starts from
    /// zero rather than picking up where an old, unrelated streak left off.
    func testDeniedStreakResetsOnTrust() {
        XCTAssertEqual(AccessibilityPermission.nextDeniedStreak(current: 5, trusted: true), 0)
    }

    /// Each untrusted check grows the streak by one.
    func testDeniedStreakGrowsWhileUntrusted() {
        XCTAssertEqual(AccessibilityPermission.nextDeniedStreak(current: 2, trusted: false), 3)
    }

    /// The reported bug this streak fixes: a single `.alreadyAsked` outcome (streak 2) must
    /// not yet warn of a stale grant — only a further repeat (streak 3) does.
    func testWarnsStaleGrantOnlyAfterRepeatedDenials() {
        XCTAssertFalse(AccessibilityPermission.warnsStaleGrant(streak: 2))
        XCTAssertTrue(AccessibilityPermission.warnsStaleGrant(streak: 3))
    }
}
