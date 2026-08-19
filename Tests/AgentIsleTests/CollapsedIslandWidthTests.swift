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
    /// Both ears at the cap + the outer insets + the `Theme.Space.md` gutters + the gap.
    /// Nothing reaches this in practice any more — each ear hugs its own content — but it
    /// is still the hard ceiling on how wide the pill can ever get.
    private var cappedWidth: CGFloat {
        CollapsedPillLayout(leftNatural: .greatestFiniteMagnitude,
                            rightNatural: .greatestFiniteMagnitude).width(notchWidth: notchWidth)
    }

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

    /// The left ear stops growing at the cap; the right ear keeps hugging its own (small)
    /// content, so the pill lands well short of the both-ears-capped ceiling.
    func testLongTitleStopsAtTheEarCap() {
        let width = pillWidth(title: "agentpeek-app-review-fff69c · feature/some-very-long-branch")
        let capped = CollapsedPillLayout(leftNatural: .greatestFiniteMagnitude, rightNatural: 0)
        XCTAssertEqual(width, capped.width(notchWidth: notchWidth), accuracy: 1,
                       "left ear should sit at the cap with the right ear hugging, got \(width)")
        XCTAssertLessThan(width, cappedWidth, "a lone long title must not widen the right ear")
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

    // MARK: - Gap centering

    /// The whole point of the shift: however lopsided the ears, the transparent gap must
    /// end up on the window's center line, because that is where the physical notch is.
    func testGapStaysCenteredForAnyEarPair() {
        for (l, r) in [(0.0, 0.0), (200.0, 12.0), (12.0, 200.0), (40.0, 95.0), (156.0, 30.0)] {
            let layout = CollapsedPillLayout(leftNatural: l, rightNatural: r)
            let pillCenter = layout.width(notchWidth: notchWidth) / 2
            let shiftedGapCenter = layout.gapCenter(notchWidth: notchWidth) + layout.offsetX
            XCTAssertEqual(shiftedGapCenter, pillCenter, accuracy: 0.001,
                           "gap drifted off center for ears (\(l), \(r))")
        }
    }

    /// Equal ears need no shift — the case the old equal-width rule forced everything into.
    func testEqualEarsNeedNoShift() {
        XCTAssertEqual(CollapsedPillLayout(leftNatural: 80, rightNatural: 80).offsetX, 0)
    }

    /// Ears never collapse below the minimum or grow past the cap.
    func testEarsAreClamped() {
        let tiny = CollapsedPillLayout(leftNatural: 0, rightNatural: 1)
        XCTAssertEqual(tiny.left, CollapsedPillLayout.minEar)
        XCTAssertEqual(tiny.right, CollapsedPillLayout.minEar)
        let huge = CollapsedPillLayout(leftNatural: 9_000, rightNatural: 9_000)
        XCTAssertEqual(huge.left, CollapsedPillLayout.maxEar)
        XCTAssertEqual(huge.right, CollapsedPillLayout.maxEar)
    }

    /// Clean style drops the status dot and agent glyph. Now that ears hug their content that
    /// has to buy real width back — with the old fixed ears it changed nothing.
    func testCleanStyleIsNarrowerThanDetailed() {
        XCTAssertLessThan(pillWidth(title: "backend", style: .clean),
                          pillWidth(title: "backend", style: .detailed),
                          "clean style should shed the dot + glyph from the ear")
    }
}
