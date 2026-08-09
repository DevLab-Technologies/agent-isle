import XCTest
import SwiftUI
@testable import AgentIsle

/// The collapsed pill overlays the menu bar, so its width is a real constraint: fixed-width
/// ears made it ~560pt wide even for a short title, crowding the status icons that flank the
/// notch. These pin the ears to their content.
///
/// Drives the `AppSettings.shared` singleton (private init), so the fields the collapsed
/// layout reads are snapshotted up front and restored in `tearDown` to avoid leaking into
/// the tester's persisted defaults.
@MainActor
final class CollapsedIslandWidthTests: XCTestCase {
    private let notchWidth: CGFloat = 185
    private let notchHeight: CGFloat = 32
    /// Ear cap (176) on both sides + the `Theme.Space.md` gutters + the notch gap.
    private var cappedWidth: CGFloat { 176 * 2 + 10 * 2 + notchWidth }

    private var savedStyle = CollapsedStyle.detailed
    private var savedSubAgents = true

    override func setUp() {
        super.setUp()
        savedStyle = AppSettings.shared.collapsedStyle
        savedSubAgents = AppSettings.shared.showSubAgents
        // Detailed is the widest style (status dot + agent glyph), so it's the worst case.
        AppSettings.shared.collapsedStyle = .detailed
        AppSettings.shared.showSubAgents = true
    }

    override func tearDown() {
        AppSettings.shared.collapsedStyle = savedStyle
        AppSettings.shared.showSubAgents = savedSubAgents
        super.tearDown()
    }

    /// Lays out the collapsed island for one session and returns the pill's rendered width.
    private func pillWidth(title: String, style: CollapsedStyle = .detailed) -> CGFloat {
        AppSettings.shared.collapsedStyle = style
        let store = SessionStore()
        store.upsert(AgentSession(agent: .claude, title: title, terminal: "iTerm",
                                  lastMessage: "Working", status: .working))
        let view = CollapsedIsland(notchWidth: notchWidth, notchHeight: notchHeight)
            .environmentObject(store)
            .environmentObject(AppSettings.shared)
        let host = NSHostingView(rootView: view)
        // Two passes: the first publishes the measured ear width, the second lays out with it.
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    func testShortTitleYieldsNarrowPill() {
        let width = pillWidth(title: "backend")
        XCTAssertLessThan(width, cappedWidth - 150,
                          "collapsed pill should hug a short title, got \(width)")
        XCTAssertGreaterThan(width, notchWidth, "pill must still be wider than the notch gap")
    }

    func testLongTitleStopsAtTheEarCap() {
        let width = pillWidth(title: "agentpeek-app-review-fff69c · feature/some-very-long-branch")
        XCTAssertEqual(width, cappedWidth, accuracy: 1,
                       "a long title should stop at the ear cap, got \(width)")
    }

    /// Both titles sit under the ear cap, so this measures the hugging itself rather than
    /// one of them bottoming out against the cap.
    func testWidthTracksTitleLengthBelowTheCap() {
        let short = pillWidth(title: "api")
        let longer = pillWidth(title: "backend")
        XCTAssertLessThan(longer, cappedWidth, "'backend' should not be hitting the cap")
        XCTAssertGreaterThan(longer, short, "pill width should track the title it shows")
    }

    /// No title should ever push the pill past the cap, however long it gets.
    func testWidthNeverExceedsTheCap() {
        for title in ["a", "backend", String(repeating: "long-branch-name·", count: 12)] {
            XCTAssertLessThanOrEqual(pillWidth(title: title), cappedWidth + 1,
                                     "pill overflowed the cap for \(title.prefix(24))")
        }
    }

    /// Clean style drops the status dot and agent glyph. Now that ears hug their content that
    /// has to buy real width back — with the old fixed ears it changed nothing.
    func testCleanStyleIsNarrowerThanDetailed() {
        XCTAssertLessThan(pillWidth(title: "backend", style: .clean),
                          pillWidth(title: "backend", style: .detailed),
                          "clean style should shed the dot + glyph from the ear")
    }
}
