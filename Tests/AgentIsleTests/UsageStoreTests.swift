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
}
