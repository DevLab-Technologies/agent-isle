import XCTest
@testable import AgentIsle

@MainActor
final class MessageSenderTests: XCTestCase {
    func testNoTargetWindowMessageNamesTheApp() {
        let message = MessageSender.SendError.noTargetWindow("Terminal").userMessage
        XCTAssertTrue(message.contains("No open Terminal window"))
    }
}
