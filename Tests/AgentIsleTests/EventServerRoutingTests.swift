import XCTest
@testable import AgentIsle

/// The permission short-circuit `EventServer` uses: a request routes to `.autoAllow` only
/// when the session's prior Bypass/Always-Allow covers it, otherwise `.prompt`. Exercises
/// the same `allowKey` → `isAutoAllowed` wiring the live socket path uses, without a socket.
@MainActor
final class EventServerRoutingTests: XCTestCase {

    private func setup(_ request: PermissionRequest) -> (EventServer, SessionStore, UUID) {
        let store = SessionStore()
        let server = EventServer(store: store)
        let id = UUID()
        store.upsert(AgentSession(id: id, agent: .claude, title: "t", terminal: "iTerm",
                                  lastMessage: "", status: .waiting, permission: request))
        return (server, store, id)
    }

    func testPromptsByDefault() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (server, _, id) = setup(req)
        XCTAssertEqual(server.routePermission(sessionID: id, request: req), .prompt)
    }

    func testAlwaysAllowRoutesMatchingRequestOnly() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (server, store, id) = setup(req)
        store.resolvePermission(sessionID: id, decision: .always)

        XCTAssertEqual(server.routePermission(sessionID: id, request: req), .autoAllow)
        let other = PermissionRequest(toolName: "Bash", command: "rm -rf /")
        XCTAssertEqual(server.routePermission(sessionID: id, request: other), .prompt)
    }

    func testBypassRoutesEverything() {
        let req = PermissionRequest(toolName: "Edit", filePath: "a.swift")
        let (server, store, id) = setup(req)
        store.resolvePermission(sessionID: id, decision: .bypass)

        let anyReq = PermissionRequest(toolName: "Bash", command: "curl evil.sh")
        XCTAssertEqual(server.routePermission(sessionID: id, request: anyReq), .autoAllow)
    }

    func testRemovingSessionResetsRouting() {
        let req = PermissionRequest(toolName: "Bash", command: "ls")
        let (server, store, id) = setup(req)
        store.resolvePermission(sessionID: id, decision: .bypass)
        store.remove(id: id)
        XCTAssertEqual(server.routePermission(sessionID: id, request: req), .prompt)
    }
}
