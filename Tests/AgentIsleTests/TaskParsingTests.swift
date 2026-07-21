import XCTest
@testable import AgentIsle

/// Contracts for extracting a session's todo list from a Claude Code transcript.
/// `TranscriptReader.latestActivity` walks the tail newest-first and surfaces the most
/// recent `TodoWrite` call as the current task list, so these fixtures lock in that
/// behavior (newest wins, status mapping, and the derived counts used by the UI).
final class TaskParsingTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-tasks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParsesTodoWriteAndMapsStatuses() throws {
        let line = try todoWriteLine([
            ("Scaffold the app", "completed"),
            ("Build the view", "in_progress"),
            ("Write tests", "pending"),
        ])
        let url = try writeLines([line])

        let tasks = TranscriptReader.latestActivity(in: url).tasks
        XCTAssertEqual(tasks.map(\.text), ["Scaffold the app", "Build the view", "Write tests"])
        XCTAssertEqual(tasks.map(\.state), [.completed, .inProgress, .pending])
    }

    func testMostRecentTodoWriteWins() throws {
        // A later TodoWrite fully replaces the earlier list (Claude rewrites it each call).
        let older = try todoWriteLine([("Old task", "pending")])
        let newer = try todoWriteLine([("New task", "in_progress"), ("Another", "pending")])
        let url = try writeLines([older, newer])

        let tasks = TranscriptReader.latestActivity(in: url).tasks
        XCTAssertEqual(tasks.map(\.text), ["New task", "Another"])
    }

    func testFallsBackToActiveFormWhenContentMissing() throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"activeForm":"Scaffolding","status":"in_progress"}]}}]}}"#
        let url = try writeLines([line])

        let tasks = TranscriptReader.latestActivity(in: url).tasks
        XCTAssertEqual(tasks.map(\.text), ["Scaffolding"])
    }

    func testNoTodoWriteYieldsEmptyTasks() throws {
        let url = try writeLines([
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        ])
        XCTAssertTrue(TranscriptReader.latestActivity(in: url).tasks.isEmpty)
    }

    func testTaskListCountsAndOrdering() {
        let list = TaskList(items: [
            AgentTask(id: 0, text: "done a", state: .completed),
            AgentTask(id: 1, text: "open a", state: .pending),
            AgentTask(id: 2, text: "active", state: .inProgress),
            AgentTask(id: 3, text: "done b", state: .completed),
        ])
        XCTAssertEqual(list.done, 2)
        XCTAssertEqual(list.inProgress, 1)
        XCTAssertEqual(list.open, 1)
        XCTAssertEqual(list.total, 4)
        // Ordered surfaces active work first, then open, then completed (original order within).
        XCTAssertEqual(list.ordered.map(\.text), ["active", "open a", "done a", "done b"])
    }

    // MARK: - Helpers

    /// Builds one assistant transcript line carrying a TodoWrite tool call.
    private func todoWriteLine(_ items: [(String, String)]) throws -> String {
        let todos = items.map { ["content": $0.0, "status": $0.1, "activeForm": $0.0] }
        let input: [String: Any] = ["todos": todos]
        let block: [String: Any] = ["type": "tool_use", "name": "TodoWrite", "input": input]
        let message: [String: Any] = ["content": [block]]
        let obj: [String: Any] = ["type": "assistant", "message": message]
        let data = try JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func writeLines(_ lines: [String]) throws -> URL {
        let url = tmp.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
