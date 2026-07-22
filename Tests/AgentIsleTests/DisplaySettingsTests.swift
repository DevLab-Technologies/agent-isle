import XCTest
@testable import AgentIsle

/// Pure-logic contracts for the display-polish preferences: the collapsed-style enum
/// (raw values, titles, and safe defaulting from a stored string) and the hover-driven
/// expand/collapse timing in `SessionStore`.
@MainActor
final class DisplaySettingsTests: XCTestCase {

    // MARK: - CollapsedStyle

    func testCollapsedStyleRawValuesAndCases() {
        XCTAssertEqual(CollapsedStyle.clean.rawValue, "clean")
        XCTAssertEqual(CollapsedStyle.detailed.rawValue, "detailed")
        XCTAssertEqual(CollapsedStyle.allCases, [.clean, .detailed])
    }

    func testCollapsedStyleTitles() {
        XCTAssertEqual(CollapsedStyle.clean.title, "Clean")
        XCTAssertEqual(CollapsedStyle.detailed.title, "Detailed")
    }

    /// The init decoder does `CollapsedStyle(rawValue: stored) ?? .detailed`, so an unknown
    /// or empty stored string must fall back to the richer default rather than crash.
    func testCollapsedStyleDefaultsToDetailedForUnknownValue() {
        XCTAssertEqual(CollapsedStyle(rawValue: "") ?? .detailed, .detailed)
        XCTAssertEqual(CollapsedStyle(rawValue: "garbage") ?? .detailed, .detailed)
        XCTAssertEqual(CollapsedStyle(rawValue: "clean") ?? .detailed, .clean)
    }

    // MARK: - Hover expand / collapse timing

    /// At the shipped defaults (0s delays) hover still expands the panel — just via the
    /// separate `hoverExpanded` signal that the views read, on the next runloop tick.
    func testHoverExpandsAtDefaultDelay() async throws {
        let store = SessionStore()
        XCTAssertFalse(store.hoverExpanded)
        store.setHovering(true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(store.hoverExpanded)
    }

    /// After the pointer leaves, `hoverExpanded` drops once the flicker debounce plus the
    /// (default 0s) auto-collapse dwell elapse.
    func testHoverCollapsesAfterExit() async throws {
        let store = SessionStore()
        store.setHovering(true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(store.hoverExpanded)
        store.setHovering(false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(store.hoverExpanded)
    }

    /// Re-entering during the collapse dwell keeps the panel open.
    func testReentryKeepsHoverExpanded() async throws {
        let store = SessionStore()
        store.setHovering(true)
        try await Task.sleep(nanoseconds: 60_000_000)
        store.setHovering(false)
        store.setHovering(true)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(store.hoverExpanded)
    }
}
