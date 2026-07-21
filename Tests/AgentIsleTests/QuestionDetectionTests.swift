import XCTest
@testable import AgentIsle

/// Contracts for detecting an unanswered `AskUserQuestion` from a transcript tail.
/// This is the poll-path question detector used for sessions Agent Isle only sees via
/// their JSONL (Desktop app, or hosts where the hook can't reach the app) — the hook
/// path never touches these fixtures.
final class QuestionDetectionTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-questions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testDetectsPendingSinglePartQuestion() throws {
        let ask = try askLine(id: "toolu_1", questions: [
            (header: "Push & PR", question: "OK to push and open a PR?",
             options: ["Yes, proceed", "No, let me review first"], multiSelect: false),
        ])
        let url = try writeLines([ask])

        let q = try XCTUnwrap(TranscriptReader.latestActivity(in: url).question)
        XCTAssertEqual(q.source, .transcript)
        XCTAssertEqual(q.parts.count, 1)
        XCTAssertEqual(q.parts[0].header, "Push & PR")
        XCTAssertEqual(q.parts[0].prompt, "OK to push and open a PR?")
        XCTAssertEqual(q.parts[0].options, ["Yes, proceed", "No, let me review first"])
        // The poll path always offers free text since it can't gate on option-only replies.
        XCTAssertTrue(q.parts[0].allowsOther)
    }

    func testAnsweredQuestionIsNotSurfaced() throws {
        // A tool_result referencing the ask's id means the user already answered it.
        let ask = try askLine(id: "toolu_1", questions: [
            (header: "Target", question: "Where to deploy?", options: ["Prod", "Staging"], multiSelect: false),
        ])
        let answer = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Prod"}]}}"#
        let url = try writeLines([ask, answer])

        XCTAssertNil(TranscriptReader.latestActivity(in: url).question)
    }

    func testMostRecentUnansweredQuestionWins() throws {
        let first = try askLine(id: "toolu_1", questions: [
            (header: "A", question: "First?", options: ["x"], multiSelect: false),
        ])
        let firstAnswer = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"x"}]}}"#
        let second = try askLine(id: "toolu_2", questions: [
            (header: "B", question: "Second?", options: ["y", "z"], multiSelect: true),
        ])
        let url = try writeLines([first, firstAnswer, second])

        let q = try XCTUnwrap(TranscriptReader.latestActivity(in: url).question)
        XCTAssertEqual(q.parts.map(\.header), ["B"])
        XCTAssertTrue(q.parts[0].multiSelect)
    }

    func testMultiPartQuestion() throws {
        let ask = try askLine(id: "toolu_1", questions: [
            (header: "Env", question: "Which env?", options: ["Prod", "Staging"], multiSelect: false),
            (header: "Notify", question: "Notify the team?", options: ["Yes", "No"], multiSelect: false),
        ])
        let url = try writeLines([ask])

        let q = try XCTUnwrap(TranscriptReader.latestActivity(in: url).question)
        XCTAssertEqual(q.parts.map(\.header), ["Env", "Notify"])
        XCTAssertEqual(q.parts.map(\.id), [0, 1])
    }

    func testNoQuestionYieldsNil() throws {
        let url = try writeLines([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]}}"#
        ])
        XCTAssertNil(TranscriptReader.latestActivity(in: url).question)
    }

    // MARK: - Helpers

    /// Builds one assistant transcript line carrying an AskUserQuestion tool call.
    private func askLine(id: String,
                         questions: [(header: String, question: String, options: [String], multiSelect: Bool)]) throws -> String {
        let wire = questions.map { q -> [String: Any] in
            [
                "header": q.header,
                "question": q.question,
                "options": q.options.map { ["label": $0, "description": ""] },
                "multiSelect": q.multiSelect,
            ]
        }
        let block: [String: Any] = ["type": "tool_use", "name": "AskUserQuestion",
                                    "id": id, "input": ["questions": wire]]
        let obj: [String: Any] = ["type": "assistant", "message": ["content": [block]]]
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeLines(_ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
