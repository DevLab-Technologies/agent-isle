import XCTest
@testable import AgentIsle

/// The Accessibility prompt is the only thing in Agent Isle that can open System Settings, and
/// macOS reopens it on *every* prompting trust check while untrusted. These lock in the rule
/// that keeps that from turning into a nag: ask once, then never again on repeat attempts, and
/// only forget the ask once real trust is observed.
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

    func testErrorMessageDistinguishesStaleGrant() {
        let first = MessageSender.SendError.accessibilityDenied(stale: false).userMessage
        let stale = MessageSender.SendError.accessibilityDenied(stale: true).userMessage
        XCTAssertNotEqual(first, stale)
        // The stale case is the one that needs the remove-and-re-add instruction.
        XCTAssertTrue(stale.localizedCaseInsensitiveContains("remove"))
    }
}
