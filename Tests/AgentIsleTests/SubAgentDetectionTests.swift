import XCTest
@testable import AgentIsle

/// Contracts for discovering a session's background sub-agents from its
/// `<session>/subagents/agent-*.jsonl` sidechain transcripts.
final class SubAgentDetectionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-subagents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadsTaskAndActivityAndWorkingState() throws {
        try writeAgent(name: "agent-1", task: "Audit the auth module for security issues",
                       lastText: "Reviewing src/auth/token.ts", ageSeconds: 2)
        try writeAgent(name: "agent-2", task: "Add tests for the i18n helpers",
                       lastText: "Wrote 4 new test files", ageSeconds: 120)

        let subs = TranscriptReader.subAgents(inDir: dir, activeWindow: 8 * 60, workingWindow: 15)
        XCTAssertEqual(subs.count, 2)

        let recent = try XCTUnwrap(subs.first { $0.id == "agent-1" })
        XCTAssertEqual(recent.title, "Audit the auth module for security issues")
        XCTAssertEqual(recent.lastMessage, "Reviewing src/auth/token.ts")
        XCTAssertTrue(recent.working)   // touched 2s ago

        let older = try XCTUnwrap(subs.first { $0.id == "agent-2" })
        XCTAssertFalse(older.working)   // touched 120s ago, past the 15s working window
    }

    func testExcludesStaleAgentsOutsideActiveWindow() throws {
        try writeAgent(name: "agent-live", task: "Live task", lastText: "working", ageSeconds: 5)
        try writeAgent(name: "agent-stale", task: "Old task", lastText: "done", ageSeconds: 60 * 60)

        let subs = TranscriptReader.subAgents(inDir: dir, activeWindow: 8 * 60, workingWindow: 15)
        XCTAssertEqual(subs.map(\.id), ["agent-live"])
    }

    func testMissingDirectoryYieldsEmpty() {
        let missing = dir.appendingPathComponent("nope")
        XCTAssertTrue(TranscriptReader.subAgents(inDir: missing, activeWindow: 8 * 60, workingWindow: 15).isEmpty)
    }

    func testCapsToMax() throws {
        for i in 0..<10 {
            try writeAgent(name: "agent-\(i)", task: "Task \(i)", lastText: "line", ageSeconds: Double(i))
        }
        let subs = TranscriptReader.subAgents(inDir: dir, activeWindow: 8 * 60, workingWindow: 15, max: 4)
        XCTAssertEqual(subs.count, 4)
    }

    // MARK: - Helpers

    /// Writes a minimal sub-agent transcript: a first `user` turn (the spawn prompt) and a
    /// later `assistant` text turn, then backdates its modification time.
    private func writeAgent(name: String, task: String, lastText: String, ageSeconds: Double) throws {
        let prompt: [String: Any] = ["type": "user", "message": ["content": task]]
        let reply: [String: Any] = ["type": "assistant",
                                    "message": ["content": [["type": "text", "text": lastText]]]]
        let lines = try [prompt, reply].map { obj -> String in
            String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let url = dir.appendingPathComponent("\(name).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let mtime = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
}
