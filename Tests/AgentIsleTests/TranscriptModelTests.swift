import XCTest
@testable import AgentIsle

/// Contracts for extracting a session's current model from a transcript. Covers both
/// `latestActivity` (Claude's per-turn `message.model`, prettified) and the generic
/// `latestModel(inJSONL:)` helper used by the external-agent adapters (raw id, checked at
/// the top level or nested). Locks in newest-wins ordering and the `<synthetic>` skip.
final class TranscriptModelTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - latestActivity (Claude, prettified)

    func testActivityReadsAndPrettifiesModel() throws {
        let url = try writeLines([assistant(model: "claude-opus-4-8", text: "hi")])
        XCTAssertEqual(TranscriptReader.latestActivity(in: url).model, "Opus 4.8")
    }

    func testActivityNewestModelWins() throws {
        // A mid-session `/model` switch appears as a newer entry; newest-first walk takes it.
        let url = try writeLines([
            assistant(model: "claude-sonnet-5", text: "earlier"),
            assistant(model: "claude-opus-4-8", text: "later"),
        ])
        XCTAssertEqual(TranscriptReader.latestActivity(in: url).model, "Opus 4.8")
    }

    func testActivitySkipsSyntheticModel() throws {
        // The newest turn is a synthetic placeholder; the real model is the prior turn.
        let url = try writeLines([
            assistant(model: "claude-sonnet-5", text: "real turn"),
            assistant(model: "<synthetic>", text: "synthetic turn"),
        ])
        XCTAssertEqual(TranscriptReader.latestActivity(in: url).model, "Sonnet 5")
    }

    func testActivityModelNilWhenAbsent() throws {
        let url = try writeLines([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"no model here"}]}}"#
        ])
        XCTAssertNil(TranscriptReader.latestActivity(in: url).model)
    }

    // MARK: - latestModel(inJSONL:) (raw, top-level or nested)

    func testLatestModelReadsNested() throws {
        let url = try writeLines([assistant(model: "claude-opus-4-8", text: "hi")])
        XCTAssertEqual(TranscriptReader.latestModel(inJSONL: url), "claude-opus-4-8")
    }

    func testLatestModelReadsTopLevel() throws {
        let url = try writeLines([#"{"type":"assistant","model":"grok-4","content":"hi"}"#])
        XCTAssertEqual(TranscriptReader.latestModel(inJSONL: url), "grok-4")
    }

    func testLatestModelNewestWinsAndSkipsSynthetic() throws {
        let url = try writeLines([
            #"{"type":"assistant","model":"grok-3","content":"old"}"#,
            #"{"type":"assistant","model":"grok-4","content":"new"}"#,
            #"{"type":"assistant","model":"<synthetic>","content":"synthetic"}"#,
        ])
        XCTAssertEqual(TranscriptReader.latestModel(inJSONL: url), "grok-4")
    }

    func testLatestModelNilWhenAbsent() throws {
        let url = try writeLines([#"{"type":"assistant","content":"no model"}"#])
        XCTAssertNil(TranscriptReader.latestModel(inJSONL: url))
    }

    // MARK: - Helpers

    private func assistant(model: String, text: String) -> String {
        let obj: [String: Any] = [
            "type": "assistant",
            "message": ["model": model, "content": [["type": "text", "text": text]]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeLines(_ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
