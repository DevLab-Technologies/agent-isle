import XCTest
@testable import AgentIsle

/// Behavioral contracts for `SessionStore`'s per-(session, kind) send-error tracking:
/// isolation between kinds, which lifecycle transitions clear it, and which don't.
@MainActor
final class SendErrorTrackingTests: XCTestCase {

    private func makeSession(status: SessionStatus = .working) -> AgentSession {
        AgentSession(agent: .claude, title: "t", terminal: "iTerm", lastMessage: "", status: status)
    }

    func testDifferentKindsDoNotClearEachOther() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)

        store.report(.scriptFailed("message failed"), sessionID: s.id, kind: .message)
        store.clearSendError(for: s.id, ifKind: .question)

        XCTAssertEqual(store.sendError(for: s.id)?.message,
                       MessageSender.SendError.scriptFailed("message failed").userMessage,
                       "clearing an unrelated kind must not touch a different kind's entry")
    }

    func testSendErrorSurfacesTheMostRecentlyReportedKind() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)

        store.report(.scriptFailed("first"), sessionID: s.id, kind: .message)
        store.report(.scriptFailed("second"), sessionID: s.id, kind: .question)

        XCTAssertEqual(store.sendError(for: s.id)?.message,
                       MessageSender.SendError.scriptFailed("second").userMessage)
    }

    func testTransitionToDoneClearsEveryKind() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)
        store.report(.scriptFailed("x"), sessionID: s.id, kind: .message)
        store.report(.scriptFailed("y"), sessionID: s.id, kind: .plan)

        store.update(id: s.id) { $0.status = .done }

        XCTAssertNil(store.sendError(for: s.id))
    }

    /// The fix this PR made deliberately narrow: a repeat or unrelated `.idle` transition
    /// (e.g. denying a permission prompt) must not wipe a still-unaddressed error from a
    /// different attempt on the same session.
    func testIdleTransitionDoesNotClearAnUnrelatedError() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)
        store.report(.scriptFailed("x"), sessionID: s.id, kind: .message)

        store.update(id: s.id) { $0.status = .idle }

        XCTAssertNotNil(store.sendError(for: s.id))
    }

    func testClosingChatClearsOnlyTheMessageKind() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)
        store.openChat(s)
        store.report(.scriptFailed("chat message failed"), sessionID: s.id, kind: .message)
        store.report(.scriptFailed("question failed"), sessionID: s.id, kind: .question)

        store.closeChat()

        // .question is shown on the row independent of chat, so it must survive.
        XCTAssertEqual(store.sendError(for: s.id)?.message,
                       MessageSender.SendError.scriptFailed("question failed").userMessage)
    }

    func testArchiveClearsEveryKind() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        store.report(.scriptFailed("x"), sessionID: s.id, kind: .message)

        store.archive(id: s.id)

        XCTAssertNil(store.sendError(for: s.id))
    }

    func testRemoveClearsEveryKind() {
        let store = SessionStore()
        let s = makeSession()
        store.upsert(s)
        store.report(.scriptFailed("x"), sessionID: s.id, kind: .message)

        store.remove(id: s.id)

        XCTAssertNil(store.sendError(for: s.id))
    }
}
