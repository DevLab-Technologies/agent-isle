import XCTest
@testable import AgentIsle

/// Contracts for `MemoryWatchdog.decide`, the pure restart decision. The threshold and
/// consecutive-count values here are arbitrary test inputs — the point is the streak logic
/// and the mid-prompt guard, not the production constants.
final class MemoryWatchdogTests: XCTestCase {

    private let threshold: UInt64 = 800
    private let required = 2

    private func decide(_ bytes: UInt64, promptActive: Bool = false, streak: Int) -> (consecutiveHigh: Int, shouldRestart: Bool) {
        MemoryWatchdog.decide(residentBytes: bytes,
                              threshold: threshold,
                              promptActive: promptActive,
                              consecutiveHigh: streak,
                              requiredConsecutive: required)
    }

    func testBelowThresholdResetsStreakAndNeverRestarts() {
        let d = decide(500, streak: 5)
        XCTAssertEqual(d.consecutiveHigh, 0)
        XCTAssertFalse(d.shouldRestart)
    }

    func testAtThresholdIsNotHigh() {
        // Strictly greater than the threshold is required; equal counts as fine.
        let d = decide(threshold, streak: 1)
        XCTAssertEqual(d.consecutiveHigh, 0)
        XCTAssertFalse(d.shouldRestart)
    }

    func testFirstHighReadingCountsButDoesNotRestart() {
        let d = decide(1000, streak: 0)
        XCTAssertEqual(d.consecutiveHigh, 1)
        XCTAssertFalse(d.shouldRestart, "one spike shouldn't trigger a restart")
    }

    func testSecondConsecutiveHighReadingRestarts() {
        let d = decide(1000, streak: 1)
        XCTAssertEqual(d.consecutiveHigh, 2)
        XCTAssertTrue(d.shouldRestart)
    }

    func testActivePromptDefersRestartButKeepsStreak() {
        let d = decide(1000, promptActive: true, streak: 5)
        XCTAssertEqual(d.consecutiveHigh, 6, "streak keeps growing while a prompt is open")
        XCTAssertFalse(d.shouldRestart, "never restart mid-prompt")
    }

    func testRestartFiresOncePromptClears() {
        // Streak accumulated while a prompt was open; next high reading with no prompt acts.
        let d = decide(1000, promptActive: false, streak: 6)
        XCTAssertTrue(d.shouldRestart)
    }

    func testDropBelowThresholdClearsAccumulatedStreak() {
        let d = decide(100, promptActive: false, streak: 6)
        XCTAssertEqual(d.consecutiveHigh, 0)
        XCTAssertFalse(d.shouldRestart)
    }
}
