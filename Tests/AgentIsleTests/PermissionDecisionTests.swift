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
        let (store, id) = store(with: PermissionRequest(toolName: "Bash", command: "ls"))
        store.resolvePermission(sessionID: id, decision: .allowOnce)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: "Bash|ls"))
    }

    func testAlwaysAllowRemembersMatchingKeyOnly() {
        let (store, id) = store(with: PermissionRequest(toolName: "Bash", command: "ls"))
        store.resolvePermission(sessionID: id, decision: .always)
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: "Bash|ls"))
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: "Bash|rm -rf"))
    }

    func testBypassAutoAllowsEverythingForTheSession() {
        let (store, id) = store(with: PermissionRequest(toolName: "Edit", filePath: "a.swift"))
        store.resolvePermission(sessionID: id, decision: .bypass)
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: "Bash|anything"))
        XCTAssertTrue(store.isAutoAllowed(sessionID: id, key: "Edit|"))
    }

    func testDenyRemembersNothing() {
        let (store, id) = store(with: PermissionRequest(toolName: "Bash", command: "ls"))
        store.resolvePermission(sessionID: id, decision: .deny)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: "Bash|ls"))
    }

    func testRemovingSessionClearsMemory() {
        let (store, id) = store(with: PermissionRequest(toolName: "Bash", command: "ls"))
        store.resolvePermission(sessionID: id, decision: .bypass)
        store.remove(id: id)
        XCTAssertFalse(store.isAutoAllowed(sessionID: id, key: "Bash|ls"))
    }
}
