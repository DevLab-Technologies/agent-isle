import XCTest
@testable import AgentIsle

/// Contracts for the session-filter matching rules and the probe/worker preset heuristic.
final class SessionFilterTests: XCTestCase {

    private func session(title: String = "fix auth",
                         workspacePath: String? = nil,
                         terminalBundleID: String? = nil,
                         agent: AgentKind = .claude,
                         status: SessionStatus = .working,
                         tasks: TaskList = TaskList(items: [])) -> AgentSession {
        AgentSession(agent: agent, title: title, terminal: "iTerm",
                     lastMessage: "", status: status,
                     tasks: tasks, workspacePath: workspacePath,
                     terminalBundleID: terminalBundleID)
    }

    // MARK: - Working-directory prefix

    func testWorkspacePrefixMatches() {
        let rule = SessionFilter(field: .workspacePath, value: "/Users/me/scratch")
        XCTAssertTrue(rule.matches(session(workspacePath: "/Users/me/scratch/proj")))
        XCTAssertFalse(rule.matches(session(workspacePath: "/Users/me/work/proj")))
    }

    func testWorkspaceRuleIgnoresSessionsWithoutPath() {
        let rule = SessionFilter(field: .workspacePath, value: "/tmp")
        XCTAssertFalse(rule.matches(session(workspacePath: nil)))
    }

    // MARK: - Title substring

    func testTitleSubstringIsCaseInsensitive() {
        let rule = SessionFilter(field: .title, value: "WIP")
        XCTAssertTrue(rule.matches(session(title: "wip: refactor")))
        XCTAssertFalse(rule.matches(session(title: "production deploy")))
    }

    // MARK: - Launcher bundle id (exact)

    func testTerminalBundleIsExactMatch() {
        let rule = SessionFilter(field: .terminalBundleID, value: "com.apple.Terminal")
        XCTAssertTrue(rule.matches(session(terminalBundleID: "com.apple.Terminal")))
        XCTAssertFalse(rule.matches(session(terminalBundleID: "com.googlecode.iterm2")))
    }

    // MARK: - Rule gating

    func testDisabledRuleNeverMatches() {
        var rule = SessionFilter(field: .title, value: "wip")
        rule.enabled = false
        XCTAssertFalse(rule.matches(session(title: "wip")))
    }

    func testEmptyValueNeverMatches() {
        let rule = SessionFilter(field: .title, value: "   ")
        XCTAssertFalse(rule.matches(session(title: "anything")))
    }

    // MARK: - Codable round-trip (persistence)

    func testFilterRoundTripsThroughJSON() throws {
        let filters = [SessionFilter(field: .workspacePath, value: "/tmp"),
                       SessionFilter(field: .title, value: "probe", enabled: false)]
        let data = try JSONEncoder().encode(filters)
        let decoded = try JSONDecoder().decode([SessionFilter].self, from: data)
        XCTAssertEqual(decoded, filters)
    }

    // MARK: - Probe/worker heuristic

    func testProbeKeywordInTitleIsHidden() {
        XCTAssertTrue(ProbeWorkerHeuristic.isProbeWorker(session(title: "health probe")))
        XCTAssertTrue(ProbeWorkerHeuristic.isProbeWorker(session(title: "background worker")))
    }

    func testTempDirectoryIsHidden() {
        XCTAssertTrue(ProbeWorkerHeuristic.isProbeWorker(
            session(workspacePath: "/private/var/folders/xy/tmp123")))
    }

    func testRealSessionIsNotHidden() {
        XCTAssertFalse(ProbeWorkerHeuristic.isProbeWorker(
            session(title: "fix auth bug", workspacePath: "/Users/me/proj")))
    }

    func testUntitledIdleUnknownAgentIsHidden() {
        XCTAssertTrue(ProbeWorkerHeuristic.isProbeWorker(
            session(title: "", agent: .unknown, status: .idle)))
    }

    func testUntitledIdleKnownAgentIsNotHidden() {
        // Only the unidentified agent case is treated as a helper; a real idle Claude isn't.
        XCTAssertFalse(ProbeWorkerHeuristic.isProbeWorker(
            session(title: "", agent: .claude, status: .idle)))
    }
}
