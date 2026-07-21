import XCTest
@testable import AgentIsle

/// Contracts for the raw-id → display-name mapping. Locks in the shapes we expect from
/// each agent's transcript and the best-effort fallback for anything unrecognized.
final class ModelNameTests: XCTestCase {

    func testClaudeNewFormat() {
        XCTAssertEqual(ModelName.pretty("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ModelName.pretty("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.pretty("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ModelName.pretty("claude-haiku-4-5-20251001"), "Haiku 4.5")
    }

    func testClaudeLegacyFormat() {
        // Family follows the version digits; the trailing date stamp is dropped.
        XCTAssertEqual(ModelName.pretty("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelName.pretty("claude-3-opus-20240229"), "Opus 3")
    }

    func testClaudeDottedVersion() {
        // An already-dotted version token is kept verbatim, not dropped.
        XCTAssertEqual(ModelName.pretty("claude-opus-4.5"), "Opus 4.5")
    }

    func testOpenAI() {
        XCTAssertEqual(ModelName.pretty("gpt-5.6"), "GPT-5.6")
        XCTAssertEqual(ModelName.pretty("gpt-5.6-codex"), "GPT-5.6 Codex")
        XCTAssertEqual(ModelName.pretty("gpt-4o"), "GPT-4o")
        XCTAssertEqual(ModelName.pretty("gpt-4.1-mini"), "GPT-4.1 Mini")
        // Reasoning models are already short and pass through unchanged.
        XCTAssertEqual(ModelName.pretty("o3"), "o3")
        XCTAssertEqual(ModelName.pretty("o4-mini"), "o4-mini")
    }

    func testGeminiAndGrok() {
        XCTAssertEqual(ModelName.pretty("gemini-2.5-pro"), "Gemini 2.5 Pro")
        XCTAssertEqual(ModelName.pretty("gemini-1.5-flash"), "Gemini 1.5 Flash")
        XCTAssertEqual(ModelName.pretty("grok-4"), "Grok 4")
        XCTAssertEqual(ModelName.pretty("grok-code-fast-1"), "Grok Code Fast 1")
    }

    func testEmptyAndAbsent() {
        XCTAssertNil(ModelName.pretty(nil))
        XCTAssertNil(ModelName.pretty(""))
        XCTAssertNil(ModelName.pretty("   "))
    }

    func testUnknownFallsBackToTidiedString() {
        // Unknown vendors still yield something readable rather than nothing.
        XCTAssertEqual(ModelName.pretty("mistral-large-latest"), "Mistral Large")
    }
}
