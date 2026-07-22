import XCTest
@testable import AgentIsle

/// Behavioral contracts for hand-dismissing (archiving) a session: it hides from
/// `visibleSessions`, stays out of the "+N hidden" filter count, and resurfaces the moment
/// its session becomes active again.
@MainActor
final class SessionArchiveTests: XCTestCase {

    private func makeSession(status: SessionStatus) -> AgentSession {
        AgentSession(agent: .claude, title: "t", terminal: "iTerm",
                     lastMessage: "", status: status)
    }

    func testArchiveHidesFromVisibleSessions() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        XCTAssertTrue(store.visibleSessions.contains { $0.id == s.id })

        store.archive(id: s.id)
        XCTAssertFalse(store.visibleSessions.contains { $0.id == s.id })
        // Archiving doesn't drop it from the underlying store, only from the visible surface.
        XCTAssertTrue(store.sessions.contains { $0.id == s.id })
    }

    func testReactivationClearsArchive() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        store.archive(id: s.id)
        XCTAssertFalse(store.visibleSessions.contains { $0.id == s.id })

        // The session picks back up — it must resurface rather than stay dismissed.
        store.update(id: s.id) { $0.status = .working }
        XCTAssertFalse(store.archivedIDs.contains(s.id))
        XCTAssertTrue(store.visibleSessions.contains { $0.id == s.id })
    }

    func testStayingDoneKeepsArchived() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        store.archive(id: s.id)

        // A quiet refresh that keeps it done/idle must not resurface it.
        store.update(id: s.id) { $0.lastMessage = "still done" }
        XCTAssertTrue(store.archivedIDs.contains(s.id))
        store.update(id: s.id) { $0.status = .idle }
        XCTAssertTrue(store.archivedIDs.contains(s.id))
        XCTAssertFalse(store.visibleSessions.contains { $0.id == s.id })
    }

    func testArchiveIsNotCountedAsHidden() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        store.archive(id: s.id)
        // Archiving is a deliberate dismissal, distinct from filter-hiding.
        XCTAssertEqual(store.hiddenCount, 0)
    }

    func testUnarchiveAllRestoresSessions() {
        let store = SessionStore()
        let a = makeSession(status: .done)
        let b = makeSession(status: .done)
        store.upsert(a)
        store.upsert(b)
        store.archive(id: a.id)
        store.archive(id: b.id)
        XCTAssertTrue(store.visibleSessions.isEmpty)

        store.unarchiveAll()
        XCTAssertEqual(store.visibleSessions.count, 2)
    }

    func testRemoveClearsArchiveSoAReusedIDReappears() {
        let store = SessionStore()
        let s = makeSession(status: .done)
        store.upsert(s)
        store.archive(id: s.id)
        store.remove(id: s.id)
        XCTAssertFalse(store.archivedIDs.contains(s.id))

        // The same id re-appearing later (a deterministic session id can recur) starts
        // visible again rather than inheriting the old archived state.
        let reused = AgentSession(id: s.id, agent: .claude, title: "t", terminal: "iTerm",
                                  lastMessage: "", status: .done)
        store.upsert(reused)
        XCTAssertTrue(store.visibleSessions.contains { $0.id == s.id })
    }
}
