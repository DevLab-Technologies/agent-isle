import XCTest
import SQLite3
import CryptoKit
@testable import AgentIsle

/// Parser contract for the Cursor CLI `store.db` format. Cursor stores each session in a
/// SQLite database with a hex-encoded-JSON `meta` row and a content-addressed `blobs`
/// DAG (JSON message blobs + protobuf linking blobs). These tests build a database shaped
/// to that reverse-engineered spec and assert the resulting metadata and `ChatMessage`
/// stream, so the format we implemented against is locked in.
final class CursorStoreTests: XCTestCase {

    private var tmp: URL!
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-cursor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParsesMetaAndConversationFromDAG() throws {
        // Three JSON message blobs: a user turn (wrapped in <user_query> tags), an
        // assistant turn (reasoning + text + tool-call), and a tool result.
        let user = Data(#"{"role":"user","content":[{"type":"text","text":"<user_query>fix the bug</user_query>"}]}"#.utf8)
        let assistant = Data(#"{"role":"assistant","content":[{"type":"reasoning","text":"Let me look"},{"type":"text","text":"On it."},{"type":"tool-call","toolName":"read_file","args":{"path":"/tmp/App/main.swift"}}]}"#.utf8)
        let toolResult = Data(#"{"role":"tool","content":[{"type":"tool-result","toolCallId":"c1","result":"line one\nline two"}]}"#.utf8)

        // A protobuf-style linking blob: [tag 0x0a][len 0x20][32-byte child hash] per
        // child, then the workspace file:// URI Cursor embeds in the root.
        var root = Data()
        for child in [user, assistant, toolResult] {
            root.append(0x0a)
            root.append(0x20)
            root.append(contentsOf: sha256Bytes(child))
        }
        root.append(contentsOf: Array("file:///Users/me/project\n".utf8))

        let metaJSON = """
        {"agentId":"sess-42","name":"Fix the parser","mode":"auto-run",\
        "createdAt":1700000000000,"lastUsedModel":"claude-4.5-opus",\
        "latestRootBlobId":"\(sha256Hex(root))"}
        """

        let db = tmp.appendingPathComponent("store.db")
        try makeStore(at: db, metaJSON: metaJSON,
                      blobs: [user, assistant, toolResult, root])

        // meta
        let meta = try XCTUnwrap(CursorStore.meta(at: db))
        XCTAssertEqual(meta.name, "Fix the parser")
        XCTAssertEqual(meta.lastUsedModel, "claude-4.5-opus")
        XCTAssertEqual(meta.agentId, "sess-42")
        XCTAssertEqual(meta.createdAt, Date(timeIntervalSince1970: 1_700_000_000))

        // conversation, in insertion order, root blob dropped
        let msgs = CursorStore.messages(at: db)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[0].blocks, [.text("fix the bug")], "query tags stripped")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].blocks, [.thinking("Let me look"),
                                        .text("On it."),
                                        .toolUse(name: "read_file", detail: "main.swift")])
        XCTAssertEqual(msgs[2].role, .assistant, "tool turns render on the assistant side")
        XCTAssertEqual(msgs[2].blocks, [.toolResult("line one\nline two")])

        // derived one-liners
        XCTAssertEqual(CursorStore.lastMessageText(at: db), "On it.")
        XCTAssertEqual(CursorStore.workspacePath(at: db), "/Users/me/project")

        // routed through the public dispatcher too
        XCTAssertTrue(ChatHistory.isSupported(.cursor))
        XCTAssertEqual(ChatHistory.messages(for: .cursor, url: db).count, 3)
    }

    func testSummaryGivesMetadataActivityAndCwdInOnePass() throws {
        let user = Data(#"{"role":"user","content":"start the build"}"#.utf8)
        let assistant = Data(#"{"role":"assistant","content":"Building now."}"#.utf8)
        var root = Data()
        for child in [user, assistant] {
            root.append(0x0a); root.append(0x20); root.append(contentsOf: sha256Bytes(child))
        }
        root.append(contentsOf: Array("file:///Users/me/app\n".utf8))

        let metaJSON = """
        {"name":"Ship it","createdAt":1700000000000,"lastUsedModel":"gpt-5.4-high",\
        "latestRootBlobId":"\(sha256Hex(root))"}
        """
        let db = tmp.appendingPathComponent("store.db")
        try makeStore(at: db, metaJSON: metaJSON, blobs: [user, assistant, root])

        let s = try XCTUnwrap(CursorStore.summary(at: db))
        XCTAssertEqual(s.meta.name, "Ship it")
        XCTAssertEqual(s.meta.lastUsedModel, "gpt-5.4-high")
        XCTAssertEqual(s.lastMessage, "Building now.", "newest text turn, no You: prefix")
        XCTAssertEqual(s.workspacePath, "/Users/me/app", "read from the root blob's file:// URI")
    }

    func testFallsBackToAllBlobsWhenRootMissing() throws {
        // No latestRootBlobId in meta -> every JSON blob is used, in insertion order.
        let a = Data(#"{"role":"user","content":"hello"}"#.utf8)
        let b = Data(#"{"role":"assistant","content":"hi there"}"#.utf8)
        let db = tmp.appendingPathComponent("store.db")
        try makeStore(at: db, metaJSON: #"{"name":"x"}"#, blobs: [a, b])

        let msgs = CursorStore.messages(at: db)
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant])
        XCTAssertEqual(msgs[1].blocks, [.text("hi there")])
    }

    func testMissingOrCorruptDatabaseYieldsNothing() throws {
        let missing = tmp.appendingPathComponent("store.db")
        XCTAssertNil(CursorStore.meta(at: missing))
        XCTAssertTrue(CursorStore.messages(at: missing).isEmpty)

        // A non-SQLite file must not throw.
        let junk = tmp.appendingPathComponent("junk.db")
        try Data("not a database".utf8).write(to: junk)
        XCTAssertNil(CursorStore.meta(at: junk))
        XCTAssertTrue(CursorStore.messages(at: junk).isEmpty)
    }

    // MARK: - Fixture helpers

    private func sha256Bytes(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Write a `store.db` with the two Cursor tables. `meta.value` is hex-encoded JSON;
    /// each blob's `id` is the hex SHA-256 of its bytes (content-addressed, as Cursor does).
    private func makeStore(at url: URL, metaJSON: String, blobs: [Data]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("could not open sqlite for fixture")
        }
        defer { sqlite3_close(db) }
        exec(db, "CREATE TABLE meta(key TEXT, value TEXT)")
        exec(db, "CREATE TABLE blobs(id TEXT, data BLOB)")

        let hexMeta = Data(metaJSON.utf8).map { String(format: "%02x", $0) }.joined()
        var m: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO meta(key,value) VALUES('0',?)", -1, &m, nil)
        sqlite3_bind_text(m, 1, hexMeta, -1, TRANSIENT)
        sqlite3_step(m); sqlite3_finalize(m)

        for data in blobs {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO blobs(id,data) VALUES(?,?)", -1, &s, nil)
            sqlite3_bind_text(s, 1, sha256Hex(data), -1, TRANSIENT)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(data.count), TRANSIENT) }
            sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
