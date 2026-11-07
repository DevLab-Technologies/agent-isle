import XCTest
@testable import AgentIsle

/// `doneAt` marks when a session's turn ended, so the transcript poller can tell a finished
/// session (fresh mtime from the final answer) from one that is still working.
@MainActor
final class DoneStateTests: XCTestCase {
    private func session(_ id: UUID, _ status: SessionStatus) -> AgentSession {
        AgentSession(id: id, agent: .claude, title: "t", terminal: "iTerm",
                     lastMessage: "", status: status)
    }

    func testTransitionIntoDoneRecordsTime() {
        let store = SessionStore()
        let id = UUID()
        store.upsert(session(id, .working))
        XCTAssertNil(store.doneAt[id])
        store.update(id: id) { $0.status = .done }
        XCTAssertNotNil(store.doneAt[id])
    }

    func testRepeatedDoneKeepsFirstMark() {
        let store = SessionStore()
        let id = UUID()
        store.upsert(session(id, .working))
        store.update(id: id) { $0.status = .done }
        let first = store.doneAt[id]
        store.update(id: id) { $0.status = .done }
        XCTAssertEqual(store.doneAt[id], first)
    }

    func testRemoveClearsMark() {
        let store = SessionStore()
        let id = UUID()
        store.upsert(session(id, .working))
        store.update(id: id) { $0.status = .done }
        store.remove(id: id)
        XCTAssertNil(store.doneAt[id])
    }
}
