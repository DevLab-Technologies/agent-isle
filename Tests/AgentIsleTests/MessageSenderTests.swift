import XCTest
@testable import AgentIsle

/// Contracts for the keystroke-path window guard: refuse to type when the target app
/// has no normal window, so a send cannot report success (or hit a new login shell)
/// after the user closed every Terminal tab.
@MainActor
final class MessageSenderTests: XCTestCase {

    private let pid: pid_t = 4242

    private func window(pid: pid_t, layer: Int) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
        ]
    }

    func testOwnerHasNormalWindowAcceptsLayerZero() {
        XCTAssertTrue(MessageSender.ownerHasNormalWindow(
            pid: pid, in: [window(pid: pid, layer: 0)]))
    }

    func testOwnerHasNormalWindowIgnoresNonZeroLayer() {
        XCTAssertFalse(MessageSender.ownerHasNormalWindow(
            pid: pid, in: [window(pid: pid, layer: 25)]))
    }

    func testOwnerHasNormalWindowIgnoresOtherPids() {
        XCTAssertFalse(MessageSender.ownerHasNormalWindow(
            pid: pid, in: [window(pid: pid + 1, layer: 0)]))
    }

    func testNoTargetWindowMessageNamesTheApp() {
        let message = MessageSender.SendError.noTargetWindow("Terminal").userMessage
        XCTAssertTrue(message.contains("No open Terminal window"))
    }
}
