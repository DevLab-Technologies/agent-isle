import XCTest
@testable import AgentIsle

/// The permission short-circuit `EventServer` uses: a request routes to `.autoAllow` only
/// when the session's prior Bypass/Always-Allow covers it, otherwise `.prompt`. Exercises
/// the same `allowKey` → `isAutoAllowed` wiring the live socket path uses, without a socket.
///
/// Also covers `requestLength` — the HTTP framer that decides when a buffered read is a
/// complete request — because a wrong length is either a crash or a hard tool denial.
@MainActor
final class EventServerRoutingTests: XCTestCase {

    private func setup(_ request: PermissionRequest) -> (EventServer, SessionStore, UUID) {
        let store = SessionStore()
        let server = EventServer(store: store, authToken: "test-token")
        let id = UUID()
        store.upsert(AgentSession(id: id, agent: .claude, title: "t", terminal: "iTerm",
                                  lastMessage: "", status: .waiting, permission: request))
        return (server, store, id)
    }

    func testRejectsMissingAndWrongToken() {
        let store = SessionStore()
        let server = EventServer(store: store, authToken: "secret-token")
        let noHeader = "POST /event HTTP/1.1\r\nContent-Type: application/json"
        XCTAssertFalse(server.isAuthorized(headerBlock: noHeader))
        let wrong = "POST /event HTTP/1.1\r\nX-Agent-Isle-Token: nope\r\nContent-Type: application/json"
        XCTAssertFalse(server.isAuthorized(headerBlock: wrong))
        let ok = "POST /event HTTP/1.1\r\nX-Agent-Isle-Token: secret-token\r\nContent-Type: application/json"
        XCTAssertTrue(server.isAuthorized(headerBlock: ok))
        // Header name is case-insensitive.
        let mixed = "POST /event HTTP/1.1\r\nx-agent-isle-token: secret-token"
        XCTAssertTrue(server.isAuthorized(headerBlock: mixed))
    }

    func testTokenParserExtractsHeader() {
        let block = "POST /event HTTP/1.1\r\nHost: localhost\r\nX-Agent-Isle-Token: abc123\r\n\r\n"
        XCTAssertEqual(EventServer.token(inHeaderBlock: block), "abc123")
        XCTAssertNil(EventServer.token(inHeaderBlock: "POST /event HTTP/1.1\r\nHost: localhost"))
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

    // MARK: - HTTP request framing

    private func httpRequest(headers: [String], body: String = "", terminate: Bool = true) -> Data {
        var text = headers.joined(separator: "\r\n")
        if terminate { text += "\r\n\r\n" }
        else { text += "\r\n" }
        return Data((text + body).utf8)
    }

    func testRequestLengthRequiresContentLength() {
        let data = httpRequest(headers: ["POST /event HTTP/1.1", "Host: 127.0.0.1"])
        XCTAssertEqual(EventServer.requestLength(in: data), .invalid)
    }

    func testRequestLengthAcceptsLowercasedContentLength() {
        let body = "{}"
        let data = httpRequest(headers: ["POST /event HTTP/1.1",
                                         "content-length: \(body.utf8.count)"],
                               body: body)
        XCTAssertEqual(EventServer.requestLength(in: data), .complete(data.count))
    }

    func testRequestLengthAcceptsMixedCaseContentLength() {
        let body = #"{"type":"status"}"#
        let data = httpRequest(headers: ["POST /event HTTP/1.1",
                                         "Content-Length: \(body.utf8.count)"],
                               body: body)
        XCTAssertEqual(EventServer.requestLength(in: data), .complete(data.count))
    }

    func testRequestLengthIncompleteWhenHeadersSplit() {
        let data = httpRequest(headers: ["POST /event HTTP/1.1", "Content-Length: 2"],
                               terminate: false)
        XCTAssertEqual(EventServer.requestLength(in: data), .incompleteHeaders)
    }

    func testRequestLengthRejectsOversizeDeclaredBody() {
        let data = httpRequest(headers: ["POST /event HTTP/1.1",
                                         "Content-Length: \(EventServer.maxRequestSize)"])
        XCTAssertEqual(EventServer.requestLength(in: data), .invalid)
    }

    func testRequestLengthRejectsIntMaxWithoutOverflow() {
        let data = httpRequest(headers: ["POST /event HTTP/1.1",
                                         "Content-Length: 9223372036854775807"])
        XCTAssertEqual(EventServer.requestLength(in: data), .invalid)
    }

    func testRequestLengthCompleteWhenBodyMatches() {
        let body = #"{"type":"status"}"#
        let data = httpRequest(headers: ["POST /event HTTP/1.1",
                                         "Content-Length: \(body.utf8.count)"],
                               body: body)
        XCTAssertEqual(EventServer.requestLength(in: data), .complete(data.count))
    }

    func testRequestLengthZeroBody() {
        let data = httpRequest(headers: ["POST /event HTTP/1.1", "Content-Length: 0"])
        XCTAssertEqual(EventServer.requestLength(in: data), .complete(data.count))
    }
}
