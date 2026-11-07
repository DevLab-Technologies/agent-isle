import XCTest
@testable import AgentIsle

final class ChatMarkdownTests: XCTestCase {
    func testBoldBulletsHeadingsAndLineBreaks() {
        let out = ChatMessageView.chatMarkdown("**Островок:**\n- первый `код`\n## Итог\nтекст")
        XCTAssertEqual(String(out.characters), "Островок:\n• первый код\nИтог\nтекст")
        let bold = out.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertTrue(bold)
    }

    func testPlainTextUnchanged() {
        let out = ChatMessageView.chatMarkdown("a * b\n#hashtag")
        XCTAssertEqual(String(out.characters), "a * b\n#hashtag")
    }
}
