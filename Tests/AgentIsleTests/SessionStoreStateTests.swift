import XCTest
@testable import AgentIsle

/// Behavioral contracts for two subtle pieces of `SessionStore` state: the hover debounce
/// (which the pointer poll relies on) and the answered-transcript-question suppression
/// (which stops the poller from resurfacing a question the user just answered).
@MainActor
final class SessionStoreStateTests: XCTestCase {

    private func question(_ prompt: String) -> AgentQuestion {
        AgentQuestion(prompt: prompt, options: ["Yes", "No"], source: .transcript)
    }

    // MARK: - Hover debounce

    func testHoverEntryIsImmediate() {
        let store = SessionStore()
        store.setHovering(true)
        XCTAssertTrue(store.isHovering)
    }

    func testHoverExitIsDebouncedThenCollapses() async throws {
        let store = SessionStore()
        store.setHovering(true)
        store.setHovering(false)
        // Still hovering synchronously — the collapse is deferred.
        XCTAssertTrue(store.isHovering)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(store.isHovering)
    }

    func testReentryCancelsPendingCollapse() async throws {
        let store = SessionStore()
        store.setHovering(true)
        store.setHovering(false)   // schedules a collapse
        store.setHovering(true)    // must cancel it
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(store.isHovering)
    }

    /// The idempotency fix: repeated "outside" reports (as a per-tick poll produces) must
    /// not keep pushing the collapse deadline back, or the island would never collapse.
    func testRepeatedExitReportsStillCollapse() async throws {
        let store = SessionStore()
        store.setHovering(true)
        // Pump `false` every 50ms for ~0.5s, the way the hover poll would while the pointer
        // sits in the dead zone. Under a naive implementation each call reschedules the
        // 0.22s deadline and it never fires.
        for _ in 0..<8 {
            store.setHovering(false)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(store.isHovering)
    }

    // MARK: - Answered-question suppression

    func testAnsweredQuestionIsSuppressedWithinGrace() {
        let store = SessionStore()
        let id = UUID()
        let q = question("Deploy?")
        store.noteAnsweredTranscriptQuestion(id, q)
        XCTAssertTrue(store.wasTranscriptQuestionAnswered(id, q))
    }

    func testReconcileClearsMarkerWhenTranscriptMovesOn() {
        let store = SessionStore()
        let id = UUID()
        let q = question("Deploy?")
        store.noteAnsweredTranscriptQuestion(id, q)
        // A different (or absent) pending question means the transcript advanced.
        store.reconcileAnsweredQuestion(id, current: question("Something else"))
        XCTAssertFalse(store.wasTranscriptQuestionAnswered(id, q))
    }

    func testReconcileKeepsMarkerWhileSameQuestionPending() {
        let store = SessionStore()
        let id = UUID()
        let q = question("Deploy?")
        store.noteAnsweredTranscriptQuestion(id, q)
        store.reconcileAnsweredQuestion(id, current: q)   // still the same pending ask
        XCTAssertTrue(store.wasTranscriptQuestionAnswered(id, q))
    }

    func testSuppressionExpiresSoAFailedDeliveryResurfaces() async throws {
        let store = SessionStore()
        store.answeredQuestionGrace = 0.1
        let id = UUID()
        let q = question("Deploy?")
        store.noteAnsweredTranscriptQuestion(id, q)
        XCTAssertTrue(store.wasTranscriptQuestionAnswered(id, q))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(store.wasTranscriptQuestionAnswered(id, q))
    }

    // MARK: - Smart suppression (auto-expand gating)

    private func session(bundle: String?) -> AgentSession {
        AgentSession(agent: .claude, title: "t", terminal: "iTerm",
                     lastMessage: "", status: .waiting, terminalBundleID: bundle)
    }

    func testSuppressesAutoExpandWhenSessionTerminalIsFrontmost() {
        let store = SessionStore()
        let s = session(bundle: "com.googlecode.iterm2")
        XCTAssertFalse(store.shouldAutoExpand(for: s, smartSuppression: true,
                                              frontmostBundleID: "com.googlecode.iterm2"))
    }

    func testExpandsWhenADifferentAppIsFrontmost() {
        let store = SessionStore()
        let s = session(bundle: "com.googlecode.iterm2")
        XCTAssertTrue(store.shouldAutoExpand(for: s, smartSuppression: true,
                                             frontmostBundleID: "com.apple.Safari"))
    }

    func testExpandsWhenSuppressionDisabledEvenIfFrontmost() {
        let store = SessionStore()
        let s = session(bundle: "com.googlecode.iterm2")
        XCTAssertTrue(store.shouldAutoExpand(for: s, smartSuppression: false,
                                             frontmostBundleID: "com.googlecode.iterm2"))
    }

    func testExpandsWhenHostBundleUnknown() {
        let store = SessionStore()
        // No terminal bundle id recorded → can't prove the user is looking at it, so surface.
        let s = session(bundle: nil)
        XCTAssertTrue(store.shouldAutoExpand(for: s, smartSuppression: true,
                                             frontmostBundleID: "com.googlecode.iterm2"))
    }
}
