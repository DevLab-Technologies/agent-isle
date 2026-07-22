import XCTest
@testable import AgentIsle

/// Grouping/label contracts for the Usage view's chart series. Regression guard for the
/// "By session" bug where two sessions in one project collapsed onto a single chart row
/// because they shared a categorical label.
@MainActor
final class UsageStoreTests: XCTestCase {

    private func record(_ id: String, _ project: String, tokens: Int) -> UsageAnalytics.Record {
        UsageAnalytics.Record(sessionID: id, project: project, projectPath: "/x/\(project)",
                              agent: .claude, day: Date(), tokens: tokens, messages: 1)
    }

    func testSessionBarsHaveUniqueLabelsWithinOneProject() {
        let store = UsageStore(records: [
            record("sess-aaaaaaaa", "ezPayments", tokens: 100),
            record("sess-bbbbbbbb", "ezPayments", tokens: 50),
        ])
        store.range = .all
        store.grouping = .session

        let bars = store.bars
        XCTAssertEqual(bars.count, 2, "each session is its own bar")
        XCTAssertEqual(Set(bars.map(\.label)).count, 2, "labels must be unique per bar")
        XCTAssertEqual(Set(bars.map(\.id)).count, 2)
    }

    func testProjectGroupingSumsAndDedupes() {
        let store = UsageStore(records: [
            record("s1", "ezPayments", tokens: 100),
            record("s2", "ezPayments", tokens: 50),
            record("s3", "qima", tokens: 30),
        ])
        store.range = .all
        store.grouping = .project

        let bars = store.bars
        XCTAssertEqual(bars.count, 2, "one bar per project")
        XCTAssertEqual(bars.first?.label, "ezPayments", "sorted by tokens desc")
        XCTAssertEqual(bars.first?.tokens, 150)
    }

    func testDayBarsCarryDateForTemporalAxis() {
        let store = UsageStore(records: [record("s1", "app", tokens: 10)])
        store.range = .all
        store.grouping = .day
        XCTAssertNotNil(store.bars.first?.date, "day bars must expose a Date for the chart axis")
    }

    // MARK: - Rolling windows

    private func event(_ agent: AgentKind, agoHours: Double, tokens: Int,
                       from now: Date) -> UsageAnalytics.Event {
        UsageAnalytics.Event(agent: agent,
                             timestamp: now.addingTimeInterval(-agoHours * 3600),
                             tokens: tokens)
    }

    func testWindowSumsRespectTheRollingBoundaries() {
        let now = Date()
        let store = UsageStore(records: [], events: [
            event(.claude, agoHours: 1, tokens: 100, from: now),    // in 5h and 7d
            event(.claude, agoHours: 4, tokens: 50, from: now),     // in 5h and 7d
            event(.claude, agoHours: 30, tokens: 40, from: now),    // only in 7d
            event(.claude, agoHours: 24 * 8, tokens: 999, from: now), // outside both
        ])

        let usage = store.windowUsage(for: .claude, now: now)
        XCTAssertNotNil(usage)
        let byWindow = Dictionary(uniqueKeysWithValues: usage!.stats.map { ($0.window, $0) })
        XCTAssertEqual(byWindow[.fiveHour]?.usedTokens, 150)
        XCTAssertEqual(byWindow[.sevenDay]?.usedTokens, 190)
    }

    func testNoCapMeansTotalsAndNoPercentage() {
        let now = Date()
        let store = UsageStore(records: [], events: [
            event(.claude, agoHours: 1, tokens: 1_200_000, from: now),
        ])
        let usage = store.windowUsage(for: .claude, now: now)
        XCTAssertEqual(usage?.hasKnownCap, false, "no caps are hardcoded by default")
        let five = usage?.stats.first { $0.window == .fiveHour }
        XCTAssertNil(five?.fraction, "without a cap there is no percentage")
        XCTAssertEqual(five?.display, "1.2M", "falls back to the raw rolling total")
    }

    func testAgentWithoutWindowModelHasNoReadout() {
        let now = Date()
        let store = UsageStore(records: [], events: [
            event(.gemini, agoHours: 1, tokens: 100, from: now),
        ])
        XCTAssertNil(store.windowUsage(for: .gemini, now: now),
                     "gemini has no known window model")
    }

    func testWindowUsageIsScopedPerAgent() {
        let now = Date()
        let store = UsageStore(records: [], events: [
            event(.claude, agoHours: 1, tokens: 100, from: now),
            event(.codex, agoHours: 1, tokens: 70, from: now),
        ])
        XCTAssertEqual(store.windowUsage(for: .claude, now: now)?
            .stats.first { $0.window == .fiveHour }?.usedTokens, 100)
        XCTAssertEqual(store.windowUsage(for: .codex, now: now)?
            .stats.first { $0.window == .fiveHour }?.usedTokens, 70)
    }
}
