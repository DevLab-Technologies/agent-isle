import XCTest
@testable import AgentIsle

/// Behavior of the richer permission decisions. "Always Allow" and "Bypass" are honored
/// entirely on the Agent Isle side (auto-answering later prompts), so these lock in the
/// `isAutoAllowed` bookkeeping that drives that.
@MainActor
final class PermissionDecisionTests: XCTestCase {

    private func store(with request: PermissionRequest) -> (SessionStore, UUID) {
        let store = SessionStore()
        let id = UUID()
        store.upsert(AgentSession(id: id, agent: .claude, title: "t", terminal: "iTerm",
                                  lastMessage: "", status: .waiting, permission: request))
        return (store, id)
    }

    func testAllowOnceDoesNotRemember() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (store, id) = store(with: req)
        store.resolvePermission(sessionID: id, decision: .allowOnce)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: req.allowKey))
    }

    func testAlwaysAllowRemembersMatchingKeyOnly() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (store, id) = store(with: req)
        store.resolvePermission(sessionID: id, decision: .always)
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: req.allowKey))
        XCTAssertFalse(store.isAutoAllowed(sessionID: id,
                                           key: PermissionRequest(toolName: "Bash", command: "rm -rf").allowKey))
    }

    func testAlwaysAllowForEditIsPerFilePath() {
        let first = PermissionRequest(toolName: "Edit", filePath: "src/a.swift")
        let (store, id) = store(with: first)
        store.resolvePermission(sessionID: id, decision: .always)
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: first.allowKey))
        // A different file must re-prompt — Always Allow is not tool-wide for path tools.
        let other = PermissionRequest(toolName: "Edit", filePath: "src/b.swift")
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: other.allowKey))
        // Same path again is covered.
        let same = PermissionRequest(toolName: "Edit", filePath: "src/a.swift")
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: same.allowKey))
    }

    func testAllowKeyIncludesCommandAndPathDiscriminators() {
        XCTAssertEqual(PermissionRequest(toolName: "Bash", command: "ls").allowKey,
                       "Bash|cmd:ls")
        XCTAssertEqual(PermissionRequest(toolName: "Edit", filePath: "a.swift").allowKey,
                       "Edit|file:a.swift")
        XCTAssertEqual(PermissionRequest(toolName: "Write").allowKey, "Write|")
    }

    func testBypassAutoAllowsEverythingForTheSession() {
        let (store, id) = store(with: PermissionRequest(toolName: "Edit", filePath: "a.swift"))
        store.resolvePermission(sessionID: id, decision: .bypass)
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: "Bash|cmd:anything"))
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: "Edit|file:other.swift"))
    }

    func testDenyRemembersNothing() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (store, id) = store(with: req)
        store.resolvePermission(sessionID: id, decision: .deny)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: req.allowKey))
    }

    func testRemovingSessionClearsMemory() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (store, id) = store(with: req)
        store.resolvePermission(sessionID: id, decision: .bypass)
        store.remove(id: id)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: req.allowKey))
    }
}
