import XCTest
@testable import AgentIsle

/// Contract for reading Claude Desktop's session store to find Claude Code sessions
/// running over SSH. The store is the only local record of those — their transcripts are
/// written on the remote host — so these fixtures lock in the on-disk shape we depend on.
final class RemoteSessionsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-remote-" + UUID().uuidString)
        // The real store nests session files two levels deep (<profile>/<workspace>),
        // so the scan has to walk rather than list.
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("profile/workspace"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFindsRemoteSessionAndReadsItsFields() throws {
        try write(session(cli: "01ac46d6-63e7-47a2-b1f6-7bed62820f3f", ssh: true),
                  name: "local_bc52b75b-2b0e-47eb-bbb1-feb80761b8c7.json")

        let found = RemoteSessions.scan(activeWindow: 600, limit: 5, root: tmp)

        XCTAssertEqual(found.count, 1)
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.cliSessionID, "01ac46d6-63e7-47a2-b1f6-7bed62820f3f")
        XCTAssertEqual(s.title, "Payment IDs missing from transaction list")
        XCTAssertEqual(s.cwd, "/home/elkhayyat/ezPayments")
        // The `user@` prefix is dropped so the card shows just the host.
        XCTAssertEqual(s.host, "ezpayments-production")
        XCTAssertEqual(s.model, ModelName.pretty("claude-opus-5"))
        // The exact remote transcript path, so the sync doesn't have to guess it.
        XCTAssertEqual(s.remoteTranscriptPath,
                       "/home/elkhayyat/.claude/projects/-home-elkhayyat-ezPayments/01ac46d6-63e7-47a2-b1f6-7bed62820f3f.jsonl")
        XCTAssertEqual(s.ssh.identityFile, "~/.ssh/ezpayments_devops")
    }

    /// The card id must match the one `IdeWatcher` derives from a transcript filename,
    /// so a session Desktop later mirrors to `projects/ssh-<cli-id>/` doesn't double up.
    func testIDMatchesTheTranscriptDerivedID() throws {
        let cli = "01ac46d6-63e7-47a2-b1f6-7bed62820f3f"
        try write(session(cli: cli, ssh: true), name: "local_a.json")

        let s = try XCTUnwrap(RemoteSessions.scan(activeWindow: 600, limit: 5, root: tmp).first)
        XCTAssertEqual(s.id, UUID.deterministic(from: cli))
    }

    /// No `sshConfig` means the session runs locally — `IdeWatcher`'s transcript poll owns
    /// it, and surfacing it here too would duplicate every local Desktop session.
    func testIgnoresLocalAndArchivedSessions() throws {
        try write(session(cli: "11111111-1111-1111-1111-111111111111", ssh: false),
                  name: "local_local.json")
        try write(session(cli: "22222222-2222-2222-2222-222222222222", ssh: true, archived: true),
                  name: "local_archived.json")

        XCTAssertTrue(RemoteSessions.scan(activeWindow: 600, limit: 5, root: tmp).isEmpty)
    }

    /// The store keeps every session ever created, so stale files must not resurface as
    /// live cards. Freshness comes from the file's mtime.
    func testIgnoresSessionsOutsideTheActiveWindow() throws {
        let url = try write(session(cli: "33333333-3333-3333-3333-333333333333", ssh: true),
                            name: "local_old.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)

        XCTAssertTrue(RemoteSessions.scan(activeWindow: 600, limit: 5, root: tmp).isEmpty)
    }

    func testDeepLinkUsesTheCLIIDWhenThereIsNoTranscript() {
        let session = AgentSession(
            id: UUID(), agent: .claude, title: "Payment IDs", terminal: "Desktop",
            lastMessage: "SSH · ezpayments-production", status: .working,
            cliSessionID: "01ac46d6-63e7-47a2-b1f6-7bed62820f3f")

        XCTAssertEqual(Jumper.claudeResumeURL(for: session)?.absoluteString,
                       "claude://resume?session=01ac46d6-63e7-47a2-b1f6-7bed62820f3f")
    }

    // MARK: - Fixtures

    /// A trimmed copy of a real `local_<uuid>.json`, keeping only the keys we read.
    private func session(cli: String, ssh: Bool, archived: Bool = false) -> String {
        let sshConfig = ssh
            ? """
              ,"sshConfig":{"sshHost":"elkhayyat@ezpayments-production","sshPort":22,
              "sshIdentityFile":"~/.ssh/ezpayments_devops"}
              """
            : ""
        return """
        {"sessionId":"local_bc52b75b-2b0e-47eb-bbb1-feb80761b8c7","cliSessionId":"\(cli)",
         "cwd":"/home/elkhayyat/ezPayments","originCwd":"/home/elkhayyat/ezPayments",
         "createdAt":1786302540717,"lastActivityAt":1786302749771,
         "model":"claude-opus-5","effort":"medium","isArchived":\(archived),
         "title":"Payment IDs missing from transaction list","titleSource":"auto",
         "sshRemoteTranscriptPath":"/home/elkhayyat/.claude/projects/-home-elkhayyat-ezPayments/\(cli).jsonl"\(sshConfig)}
        """
    }

    @discardableResult
    private func write(_ contents: String, name: String) throws -> URL {
        let url = tmp.appendingPathComponent("profile/workspace").appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Contract for the SSH command that mirrors a remote transcript. The command text is a
/// pure function, so it can be asserted without touching the network; the transfer itself
/// is exercised against a real host by hand.
final class RemoteTranscriptSyncTests: XCTestCase {

    private func command(path: String?, offset: Int) -> String {
        RemoteTranscriptSync.remoteCommand(
            cliSessionID: "01ac46d6-63e7-47a2-b1f6-7bed62820f3f",
            path: path, offset: offset, initialByteCap: 8 * 1024 * 1024)
    }

    /// Desktop records the exact remote path; using it covers hosts where the transcript
    /// isn't under the SSH user's home (a root session, a worktree's own directory).
    func testUsesTheRecordedRemotePath() {
        let cmd = command(path: "/home/elkhayyat/.claude/projects/-home-x/s.jsonl", offset: 0)
        XCTAssertTrue(cmd.contains("f='/home/elkhayyat/.claude/projects/-home-x/s.jsonl'"))
        XCTAssertFalse(cmd.contains("ls -1t"))
    }

    func testFallsBackToLocatingBySessionIDWhenNoPathRecorded() {
        let cmd = command(path: nil, offset: 0)
        XCTAssertTrue(cmd.contains("ls -1t \"$HOME\"/.claude/projects/*/01ac46d6-63e7-47a2-b1f6-7bed62820f3f.jsonl"))
    }

    /// The first sync takes a bounded tail; later ones resume from the byte we stopped at.
    /// `tail -c +N` is 1-indexed, so resuming at offset N asks for +N+1.
    func testFetchesOnlyTheDeltaAfterTheFirstSync() {
        XCTAssertTrue(command(path: "/t.jsonl", offset: 0).contains("tail -c 8388608"))
        XCTAssertTrue(command(path: "/t.jsonl", offset: 4096).contains("tail -c +4097"))
    }

    /// Every command reports the file's size first, which is how a truncated or replaced
    /// transcript is detected instead of appending a delta onto a stale mirror.
    func testReportsTheFileSizeFirst() {
        XCTAssertTrue(command(path: "/t.jsonl", offset: 10).contains("wc -c < \"$f\""))
    }

    /// The path comes from JSON we don't author, so it must reach the remote shell as one
    /// literal word — it can't close the quote and append a command.
    func testQuotesPathsSoTheyCannotExtendTheCommand() {
        let hostile = "/tmp/a'; rm -rf ~; echo '.jsonl"
        XCTAssertEqual(RemoteTranscriptSync.shellQuoted(hostile),
                       "'/tmp/a'\\''; rm -rf ~; echo '\\''.jsonl'")
        XCTAssertFalse(command(path: hostile, offset: 0).contains("f='/tmp/a'; rm"))
    }

    func testReadsConnectionDetails() throws {
        let target = try XCTUnwrap(RemoteSessions.target(from: [
            "sshHost": "elkhayyat@ezpayments-production",
            "sshPort": 2222,
            "sshIdentityFile": "~/.ssh/id_ed25519",
        ]))
        XCTAssertEqual(target.destination, "elkhayyat@ezpayments-production")
        XCTAssertEqual(target.port, 2222)
        XCTAssertEqual(target.displayHost, "ezpayments-production")
    }

    /// Without a host there is nothing to connect to, so the session is not surfaced.
    func testRejectsAnEmptyHost() {
        XCTAssertNil(RemoteSessions.target(from: ["sshHost": ""]))
        XCTAssertNil(RemoteSessions.target(from: [:]))
    }
}
