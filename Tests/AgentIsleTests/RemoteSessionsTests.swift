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
         "title":"Payment IDs missing from transaction list","titleSource":"auto"\(sshConfig)}
        """
    }

    @discardableResult
    private func write(_ contents: String, name: String) throws -> URL {
        let url = tmp.appendingPathComponent("profile/workspace").appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
