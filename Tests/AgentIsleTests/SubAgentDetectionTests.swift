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

    private var cache: [String: TranscriptReader.SubAgentCache] = [:]

    private func read(activeWindow: TimeInterval = 8 * 60, workingWindow: TimeInterval = 15,
                      max: Int = 8) -> [SubAgent] {
        TranscriptReader.subAgents(inDir: dir, activeWindow: activeWindow,
                                   workingWindow: workingWindow, max: max, cache: &cache)
    }

    func testReadsTaskAndActivityAndWorkingState() throws {
        try writeAgent(name: "agent-1", task: "Audit the auth module for security issues",
                       lastText: "Reviewing src/auth/token.ts", ageSeconds: 2)
        try writeAgent(name: "agent-2", task: "Add tests for the i18n helpers",
                       lastText: "Wrote 4 new test files", ageSeconds: 120)

        let subs = read()
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

        XCTAssertEqual(read().map(\.id), ["agent-live"])
    }

    func testMissingDirectoryYieldsEmpty() {
        var c: [String: TranscriptReader.SubAgentCache] = [:]
        let missing = dir.appendingPathComponent("nope")
        XCTAssertTrue(TranscriptReader.subAgents(inDir: missing, activeWindow: 8 * 60,
                                                 workingWindow: 15, cache: &c).isEmpty)
    }

    func testCapsToMax() throws {
        for i in 0..<10 {
            try writeAgent(name: "agent-\(i)", task: "Task \(i)", lastText: "line", ageSeconds: Double(i))
        }
        XCTAssertEqual(read(max: 4).count, 4)
    }

    func testCacheReusesUnchangedFilesAndRefreshesChangedOnes() throws {
        try writeAgent(name: "agent-1", task: "Original task", lastText: "first activity", ageSeconds: 2)
        _ = read()
        XCTAssertEqual(cache["agent-1"]?.lastMessage, "first activity")

        // Rewrite with a NEW mtime and new activity: the cache should refresh.
        try writeAgent(name: "agent-1", task: "Original task", lastText: "second activity", ageSeconds: 1)
        let refreshed = read()
        XCTAssertEqual(refreshed.first?.lastMessage, "second activity")

        // Rewrite the content but restore the SAME mtime as the cache holds: the cached
        // value is reused (the on-disk change is intentionally ignored, proving no re-read).
        let held = try XCTUnwrap(cache["agent-1"]?.mtime)
        let url = dir.appendingPathComponent("agent-1.jsonl")
        try makeAgentFile(at: url, task: "Original task", lastText: "third activity")
        try FileManager.default.setAttributes([.modificationDate: held], ofItemAtPath: url.path)
        XCTAssertEqual(read().first?.lastMessage, "second activity")
    }

    // MARK: - Helpers

    /// Writes a minimal sub-agent transcript: a first `user` turn (the spawn prompt) and a
    /// later `assistant` text turn, then backdates its modification time.
    private func writeAgent(name: String, task: String, lastText: String, ageSeconds: Double) throws {
        let url = dir.appendingPathComponent("\(name).jsonl")
        try makeAgentFile(at: url, task: task, lastText: lastText)
        let mtime = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    /// Writes the transcript content only (leaves the modification time to the caller).
    private func makeAgentFile(at url: URL, task: String, lastText: String) throws {
        let prompt: [String: Any] = ["type": "user", "message": ["content": task]]
        let reply: [String: Any] = ["type": "assistant",
                                    "message": ["content": [["type": "text", "text": lastText]]]]
        let lines = try [prompt, reply].map { obj -> String in
            String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
