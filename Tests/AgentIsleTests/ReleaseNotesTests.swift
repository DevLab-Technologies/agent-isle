import AppKit
import XCTest
@testable import AgentIsle

/// Contracts for `ReleaseNotes.attributed`, which turns a GitHub release body (Markdown) into
/// the styled text shown in the update prompt. The assertions target what the user actually
/// sees: no leftover Markdown syntax, headings and list markers intact, links preserved.
final class ReleaseNotesTests: XCTestCase {

    private func attributes(of rendered: NSAttributedString,
                            at index: Int) -> [NSAttributedString.Key: Any] {
        rendered.attributes(at: index, effectiveRange: nil)
    }

    func testEmptyNotesRenderNothing() {
        XCTAssertEqual(ReleaseNotes.attributed("").length, 0)
        XCTAssertEqual(ReleaseNotes.attributed("   \n\n  ").length, 0)
    }

    func testHeadingSyntaxIsStrippedAndStyled() {
        let rendered = ReleaseNotes.attributed("## Agent Isle v1.6\n\nA line.")
        XCTAssertFalse(rendered.string.contains("#"))
        XCTAssertTrue(rendered.string.hasPrefix("Agent Isle v1.6"))

        let headingFont = attributes(of: rendered, at: 0)[.font] as? NSFont
        let bodyIndex = rendered.string.distance(from: rendered.string.startIndex,
                                                 to: rendered.string.range(of: "A line.")!.lowerBound)
        let bodyFont = attributes(of: rendered, at: bodyIndex)[.font] as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertNotNil(bodyFont)
        XCTAssertGreaterThan(headingFont!.pointSize, bodyFont!.pointSize)
    }

    func testBulletsGetMarkersAndLoseSyntax() {
        let rendered = ReleaseNotes.attributed("- First item\n- Second item")
        XCTAssertTrue(rendered.string.contains("•  First item"))
        XCTAssertTrue(rendered.string.contains("•  Second item"))
        XCTAssertFalse(rendered.string.contains("- First"))
    }

    func testNestedBulletsIndent() {
        let rendered = ReleaseNotes.attributed("- Outer\n  - Inner")
        XCTAssertTrue(rendered.string.contains("◦  Inner"))

        let innerIndex = rendered.string.distance(from: rendered.string.startIndex,
                                                  to: rendered.string.range(of: "Inner")!.lowerBound)
        let outerIndex = rendered.string.distance(from: rendered.string.startIndex,
                                                  to: rendered.string.range(of: "Outer")!.lowerBound)
        let inner = attributes(of: rendered, at: innerIndex)[.paragraphStyle] as? NSParagraphStyle
        let outer = attributes(of: rendered, at: outerIndex)[.paragraphStyle] as? NSParagraphStyle
        XCTAssertGreaterThan(inner?.headIndent ?? 0, outer?.headIndent ?? 0)
    }

    func testOrderedListsKeepTheirNumbers() {
        let rendered = ReleaseNotes.attributed("1. First\n2. Second")
        XCTAssertTrue(rendered.string.contains("1. First"))
        XCTAssertTrue(rendered.string.contains("2. Second"))
    }

    func testInlineEmphasisIsAppliedNotPrinted() {
        let rendered = ReleaseNotes.attributed("**They appear now.** Discovered from the store.")
        XCTAssertFalse(rendered.string.contains("*"))
        let font = attributes(of: rendered, at: 0)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testInlineCodeIsMonospacedWithoutBackticks() {
        let rendered = ReleaseNotes.attributed("Run `xattr` first.")
        XCTAssertFalse(rendered.string.contains("`"))
        let index = rendered.string.distance(from: rendered.string.startIndex,
                                             to: rendered.string.range(of: "xattr")!.lowerBound)
        let font = attributes(of: rendered, at: index)[.font] as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
    }

    func testLinksSurviveAsAttributes() {
        let rendered = ReleaseNotes.attributed("See the [releases page](https://example.com/r).")
        XCTAssertTrue(rendered.string.contains("releases page"))
        XCTAssertFalse(rendered.string.contains("https://example.com/r"))
        let index = rendered.string.distance(from: rendered.string.startIndex,
                                             to: rendered.string.range(of: "releases page")!.lowerBound)
        let link = attributes(of: rendered, at: index)[.link]
        XCTAssertEqual((link as? URL)?.absoluteString, "https://example.com/r")
    }

    func testBlocksAreSeparatedByNewlines() {
        let rendered = ReleaseNotes.attributed("### Fixes\n- One\n- Two")
        XCTAssertEqual(rendered.string, "Fixes\n•  One\n•  Two")
    }

    func testNotesAreNotTruncated() {
        // The old prompt cut notes at 500 characters; the scrollable view shows all of them.
        let body = (1...60).map { "- Item number \($0) with some descriptive text" }.joined(separator: "\n")
        let rendered = ReleaseNotes.attributed(body)
        XCTAssertTrue(rendered.string.contains("Item number 60"))
        XCTAssertGreaterThan(rendered.length, 500)
    }

    func testPlainTextMatchesRenderedString() {
        let body = "## Title\n\n- **Bold** item"
        XCTAssertEqual(ReleaseNotes.plainText(body), ReleaseNotes.attributed(body).string)
    }
}
