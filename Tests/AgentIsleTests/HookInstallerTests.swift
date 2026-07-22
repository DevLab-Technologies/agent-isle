import XCTest
@testable import AgentIsle

/// Locks in the pure JSON transforms behind the generalized hook installer: idempotent
/// installs, preservation of foreign hooks, and clean removal for both the Claude Code and
/// Cursor config shapes. These run without the app bundle or any filesystem writes.
final class HookInstallerTests: XCTestCase {

    private let marker = "agent-isle-hook"
    private let cursorMarker = "agent-isle-cursor-hook"
    private let claudeEvents = [
        HookEvent(name: "PreToolUse", scriptArg: "pretooluse", timeout: 300, matcher: "*"),
        HookEvent(name: "Stop", scriptArg: "stop", timeout: nil, matcher: nil),
    ]
    private let cursorEvents = [
        HookEvent(name: "beforeShellExecution", scriptArg: nil, timeout: 300, matcher: nil),
        HookEvent(name: "stop", scriptArg: nil, timeout: nil, matcher: nil),
    ]

    private func command(_ path: String) -> (HookEvent, GenericHookInstaller.Format) -> String {
        GenericHookInstaller.commandBuilder(scriptPath: path, agentName: "claude")
    }

    // MARK: Claude format

    func testClaudeInstallAddsMarkedHooksWithMatcherAndTimeout() {
        let out = GenericHookInstaller.applyingHook(
            to: [:], format: .claude, events: claudeEvents, marker: marker,
            command: command("/tmp/agent-isle-hook.py"))
        let hooks = out["hooks"] as? [String: Any]
        let pre = (hooks?["PreToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(pre?["matcher"] as? String, "*")
        let cmd = (pre?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(cmd?["timeout"] as? Int, 300)
        XCTAssertTrue((cmd?["command"] as? String)?.contains(marker) == true)
        XCTAssertTrue((cmd?["command"] as? String)?.contains("--agent claude") == true)
        // Stop has no matcher key and no timeout.
        let stop = (hooks?["Stop"] as? [[String: Any]])?.first
        XCTAssertNil(stop?["matcher"])
        XCTAssertNil((stop?["hooks"] as? [[String: Any]])?.first?["timeout"])
    }

    func testClaudeInstallIsIdempotent() {
        let once = GenericHookInstaller.applyingHook(
            to: [:], format: .claude, events: claudeEvents, marker: marker,
            command: command("/tmp/agent-isle-hook.py"))
        let twice = GenericHookInstaller.applyingHook(
            to: once, format: .claude, events: claudeEvents, marker: marker,
            command: command("/tmp/agent-isle-hook.py"))
        let groups = (twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 1, "Re-installing must not duplicate our hook group")
    }

    func testClaudePreservesForeignHooksAndUninstallLeavesThem() {
        let foreign: [String: Any] = ["hooks": [
            "PreToolUse": [["hooks": [["type": "command", "command": "/usr/bin/other-tool"]]]],
        ]]
        let installed = GenericHookInstaller.applyingHook(
            to: foreign, format: .claude, events: claudeEvents, marker: marker,
            command: command("/tmp/agent-isle-hook.py"))
        let pre = (installed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2, "Foreign group kept, ours appended")

        let removed = GenericHookInstaller.removingHook(from: installed, format: .claude, marker: marker)
        let preAfter = (removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(preAfter?.count, 1)
        let survivingCmd = (preAfter?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertEqual(survivingCmd, "/usr/bin/other-tool")
        // Stop was only ours, so its key is dropped entirely.
        XCTAssertNil((removed["hooks"] as? [String: Any])?["Stop"])
    }

    // MARK: Cursor format

    func testCursorInstallSetsVersionAndFlatEntries() {
        let out = GenericHookInstaller.applyingHook(
            to: [:], format: .cursor, events: cursorEvents, marker: cursorMarker,
            command: GenericHookInstaller.commandBuilder(scriptPath: "/tmp/agent-isle-cursor-hook.py", agentName: "cursor"))
        XCTAssertEqual(out["version"] as? Int, 1)
        let entry = ((out["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]])?.first
        XCTAssertEqual(entry?["timeout"] as? Int, 300)
        XCTAssertNil(entry?["type"], "Cursor entries are flat {command, timeout?} with no type")
    }

    func testCursorUninstallRemovesOnlyOursAndClearsEmptyHooks() {
        let installed = GenericHookInstaller.applyingHook(
            to: [:], format: .cursor, events: cursorEvents, marker: cursorMarker,
            command: GenericHookInstaller.commandBuilder(scriptPath: "/tmp/agent-isle-cursor-hook.py", agentName: "cursor"))
        let removed = GenericHookInstaller.removingHook(from: installed, format: .cursor, marker: cursorMarker)
        XCTAssertNil(removed["hooks"], "With only our hooks, the hooks map is removed entirely")
        XCTAssertEqual(removed["version"] as? Int, 1, "Unrelated keys are preserved")
    }

    // MARK: Registry

    func testRegistryExposesHookCapableAndMonitorAgents() {
        XCTAssertEqual(CLIIntegration.hookCapable.map(\.agent), [.claude, .cursor])
        XCTAssertEqual(CLIIntegration.claude.capability, .hook)
        XCTAssertEqual(CLIIntegration.grok.capability, .liveChat)   // history-parsed
        XCTAssertEqual(CLIIntegration.gemini.capability, .monitorOnly)
    }
}
