import XCTest
@testable import AgentIsle

/// Parser contracts for the non-Claude chat-history formats. The parsers are pure
/// functions over a file, so we write small fixtures to a temp dir and assert the
/// resulting `ChatMessage` stream. This locks in the on-disk shapes we reverse-engineered
/// for Grok CLI and GitHub Copilot CLI.
final class ChatHistoryTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = try makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Grok

    func testGrokParsesEachEntryKind() throws {
        // system → skipped; user (blocks); reasoning (summary); assistant (text + tool_call);
        // tool_result. Mirrors chat_history.jsonl.
        let lines = [
            #"{"type":"system","content":"you are grok"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>fix the bug</user_query>"}]}"#,
            #"{"type":"reasoning","summary":[{"type":"summary_text","text":"Let me look at the code"}]}"#,
            #"{"type":"assistant","content":"On it.","tool_calls":[{"id":"c1","name":"read_file","arguments":"{\"path\":\"/tmp/App/main.swift\"}"}]}"#,
            #"{"type":"tool_result","tool_call_id":"c1","content":"line one\nline two"}"#,
        ]
        let url = try writeLines(lines, to: "chat_history.jsonl")

        let msgs = ChatHistory.messages(for: .grok, url: url)
        XCTAssertEqual(msgs.count, 4, "system entry should be dropped")

        // user: <user_query> tags stripped.
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[0].blocks, [.text("fix the bug")])

        // reasoning → assistant thinking.
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].blocks, [.thinking("Let me look at the code")])

        // assistant: text + tool_use with detail pulled from the JSON arguments (basename).
        XCTAssertEqual(msgs[2].role, .assistant)
        XCTAssertEqual(msgs[2].blocks, [.text("On it."), .toolUse(name: "read_file", detail: "main.swift")])

        // tool_result → assistant side.
        XCTAssertEqual(msgs[3].role, .assistant)
        XCTAssertEqual(msgs[3].blocks, [.toolResult("line one\nline two")])
    }

    func testGrokUserPlainStringContent() throws {
        let url = try writeLines([#"{"type":"user","content":"hello there"}"#], to: "chat_history.jsonl")
        let msgs = ChatHistory.messages(for: .grok, url: url)
        XCTAssertEqual(msgs.map(\.role), [.user])
        XCTAssertEqual(msgs.first?.blocks, [.text("hello there")])
    }

    func testGrokKeepsOnlyMostRecentUpToLimit() throws {
        let lines = (0..<10).map { #"{"type":"user","content":"m\#($0)"}"# }
        let url = try writeLines(lines, to: "chat_history.jsonl")
        let msgs = ChatHistory.messages(for: .grok, url: url, limit: 3)
        XCTAssertEqual(msgs.count, 3)
        // Suffix is retained: the last three messages, in order.
        XCTAssertEqual(msgs.map(\.blocks), [[.text("m7")], [.text("m8")], [.text("m9")]])
    }

    func testGrokSkipsMalformedLines() throws {
        let lines = [
            "not json at all",
            #"{"type":"user","content":"good"}"#,
            "{ broken",
        ]
        let url = try writeLines(lines, to: "chat_history.jsonl")
        let msgs = ChatHistory.messages(for: .grok, url: url)
        XCTAssertEqual(msgs.map(\.blocks), [[.text("good")]])
    }

    // MARK: - Copilot

    func testCopilotParsesRolesAndToolCalls() throws {
        let json = """
        {"sessionId":"s1","chatMessages":[
          {"role":"user","content":"add a feature"},
          {"role":"assistant","content":"Sure."},
          {"role":"assistant","tool_calls":[{"type":"function","id":"t1","function":{"name":"str_replace_editor","arguments":"{\\"command\\":\\"view\\",\\"path\\":\\"/Users/me/proj/app.ts\\"}"}}]},
          {"role":"tool","tool_call_id":"t1","content":"file contents"}
        ]}
        """
        let url = try write(json, to: "session_1.json")

        let msgs = ChatHistory.messages(for: .copilot, url: url)
        XCTAssertEqual(msgs.count, 4)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[0].blocks, [.text("add a feature")])
        XCTAssertEqual(msgs[1].blocks, [.text("Sure.")])
        XCTAssertEqual(msgs[2].blocks, [.toolUse(name: "str_replace_editor", detail: "app.ts")])
        XCTAssertEqual(msgs[3].role, .assistant)
        XCTAssertEqual(msgs[3].blocks, [.toolResult("file contents")])
    }

    func testCopilotEmptyOrMissingKeyYieldsNothing() throws {
        let url = try write(#"{"sessionId":"s1"}"#, to: "session_2.json")
        XCTAssertTrue(ChatHistory.messages(for: .copilot, url: url).isEmpty)
    }

    // MARK: - Dispatcher / support

    func testMissingFileYieldsNoMessages() {
        let missing = tmp.appendingPathComponent("nope.jsonl")
        XCTAssertTrue(ChatHistory.messages(for: .grok, url: missing).isEmpty)
        XCTAssertTrue(ChatHistory.messages(for: .copilot, url: missing).isEmpty)
    }

    func testIsSupported() {
        XCTAssertTrue(ChatHistory.isSupported(.claude))
        XCTAssertTrue(ChatHistory.isSupported(.grok))
        XCTAssertTrue(ChatHistory.isSupported(.copilot))
        XCTAssertTrue(ChatHistory.isSupported(.cursor))
        XCTAssertTrue(ChatHistory.isSupported(.codex))
        XCTAssertTrue(ChatHistory.isSupported(.goose))
        XCTAssertFalse(ChatHistory.isSupported(.aider))
        XCTAssertFalse(ChatHistory.isSupported(.unknown))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeLines(_ lines: [String], to name: String) throws -> URL {
        try write(lines.joined(separator: "\n") + "\n", to: name)
    }
}
