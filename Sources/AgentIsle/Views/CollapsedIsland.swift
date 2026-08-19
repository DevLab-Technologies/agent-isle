import SwiftUI

/// The resting state: a slim black pill hugging the notch that surfaces the most
/// attention-worthy session plus a count badge.
struct CollapsedIsland: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings

    private var focus: AgentSession? { store.focusSession }

    /// How many of the focus session's sub-agents are actively working right now.
    private var workingSubAgents: Int {
        focus?.subAgents.filter(\.working).count ?? 0
    }

    /// Natural widths of the two ears, measured off-screen (see `earMeasurement`).
    @State private var leftNatural: CGFloat = 0
    @State private var rightNatural: CGFloat = 0

    /// Each ear hugs its own content; `CollapsedPillLayout.offsetX` then slides the pill so
    /// the transparent center gap still lands on the physical notch.
    private var layout: CollapsedPillLayout {
        CollapsedPillLayout(leftNatural: leftNatural, rightNatural: rightNatural)
    }

    /// Color of the "needs you" signal — amber for a pending permission, purple for a
    /// question, teal for a plan review, matching the per-status colors used elsewhere.
    /// Ordered by urgency so the most blocking state wins when several are pending.
    private var attentionColor: Color {
        if store.visibleSessions.contains(where: { $0.status == .waiting }) { return SessionStatus.waiting.color }
        if store.visibleSessions.contains(where: { $0.status == .asking }) { return SessionStatus.asking.color }
        return SessionStatus.planning.color
    }

    var body: some View {
        // A fixed center gap the width of the physical notch, flanked by two ears that
        // each hug their own content. The pill is therefore lopsided in general; the
        // `.offset` below puts the gap back on the notch so text never hides behind it.
        HStack(spacing: 0) {
            leftCluster
                .frame(width: layout.left, alignment: .trailing)
                .padding(.leading, Theme.Space.edge)
                .padding(.trailing, Theme.Space.md)
            Color.clear
                .frame(width: notchWidth)   // the physical notch lives here
            rightCluster
                .frame(width: layout.right, alignment: .leading)
                .padding(.leading, Theme.Space.md)
                .padding(.trailing, Theme.Space.edge)
        }
        .frame(height: max(notchHeight, 30))
        .background(surface)
        .background(earMeasurement)
        .onPreferenceChange(LeftEarWidthKey.self) { leftNatural = $0 }
        .onPreferenceChange(RightEarWidthKey.self) { rightNatural = $0 }
        .fixedSize()
        // Layout stays symmetric about the pill's own center; the shift is purely visual,
        // so the reported island size is unaffected. The window's click-through rect reads
        // the same value (see `IslandOffsetKey`) so hover and taps follow the pill.
        .offset(x: layout.offsetX)
        .preference(key: IslandOffsetKey.self, value: layout.offsetX)
    }

    /// The pill itself: notch-continuous black, a bottom-lit rim so the silhouette still
    /// reads on a dark desktop (pure black on black has no edge at all), and a soft shadow
    /// that grounds it on a light one.
    private var surface: some View {
        let shape = NotchShape(topRadius: Theme.Radius.notchFlare,
                               bottomRadius: Theme.Radius.notchBottom)
        return ZStack {
            shape.fill(.black)
            shape.stroke(Theme.Fill.rim, lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
    }

    /// Renders both ears at their natural width, hidden and outside the visible layout, so
    /// each can be sized to its own content. Lives in a `.background` so it never
    /// contributes to the pill's own size; the clusters here don't read the measured
    /// widths, so there's no measurement feedback loop.
    private var earMeasurement: some View {
        ZStack {
            leftCluster.background(widthReporter(LeftEarWidthKey.self))
            rightCluster.background(widthReporter(RightEarWidthKey.self))
        }
        .fixedSize()
        .hidden()
        // `.hidden()` stops drawing, not instantiation: these clusters still run their
        // `onAppear`, so without this flag the pill would drive a second, permanently
        // invisible copy of every repeating animation for as long as the app is up.
        .environment(\.isMeasuringIsland, true)
    }

    private func widthReporter<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.width)
        }
    }

    /// Clean mode strips the pill back to the focus session's title and the count; detailed
    /// mode keeps the status dot, agent glyph, live pulse, and sub-agent badge.
    private var isClean: Bool { settings.collapsedStyle == .clean }

    @ViewBuilder private var leftCluster: some View {
        if let s = focus {
            HStack(spacing: Theme.Space.sm) {
                if !isClean {
                    StatusDot(status: s.status)
                    Text(s.agent.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(s.agent.glyphTint.opacity(0.9))
                }
                Text(s.title)
                    .font(Theme.Font.pillTitle())
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            AppMark(size: 15)
        }
    }

    // Right ear reads outward from the notch: the live signal first, then a muted total.
    // Only the most useful thing shows — no ambiguous "•••", and no lone "1".
    // In clean mode only the count survives; the live signals belong to detailed mode.
    @ViewBuilder private var rightCluster: some View {
        HStack(spacing: Theme.Space.sm) {
            if !isClean {
                if store.attentionCount > 0 {
                    CountBadge(count: store.attentionCount, color: attentionColor)
                } else if store.workingCount > 0 {
                    LivePulse(color: SessionStatus.working.color)
                }
            }
            // How many sub-agents the surfaced session is running, right by the pulse.
            if !isClean, settings.showSubAgents, workingSubAgents > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(workingSubAgents)")
                        .font(Theme.Font.numeral(9.5))
                }
                .foregroundStyle(SessionStatus.working.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(SessionStatus.working.color.opacity(0.14)))
            }
            if store.visibleSessions.count > 1 {
                Text("\(store.visibleSessions.count)")
                    .font(Theme.Font.numeral())
                    .foregroundStyle(Theme.Ink.secondary)
                    .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Fill.card))
            }
        }
    }
}

/// True inside the collapsed pill's off-screen measuring pass, so views that would start a
/// perpetual animation on appear can sit that copy out.
private struct IsMeasuringIslandKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var isMeasuringIsland: Bool {
        get { self[IsMeasuringIslandKey.self] }
        set { self[IsMeasuringIslandKey.self] = newValue }
    }
}

/// Ear widths and the shift that keeps the notch gap on the notch. Split out from the view
/// so the invariant — gap center == pill center, whatever the two ears measure — is
/// directly testable.
struct CollapsedPillLayout: Equatable {
    /// Keeps the pill a recognisable island rather than a sliver when there's little to show.
    static let minEar: CGFloat = 30
    /// Past this an ear stops growing and its content truncates. A fixed ear width made the
    /// pill ~570pt wide even for a short title, which crowded (and on busier menu bars
    /// covered) the status icons flanking the notch. The cap covers content only:
    /// `Theme.Space.edge` of outer inset sits outside it.
    static let maxEar: CGFloat = 176 - Theme.Space.edge

    let left: CGFloat
    let right: CGFloat

    init(leftNatural: CGFloat, rightNatural: CGFloat) {
        left = Self.clamped(leftNatural)
        right = Self.clamped(rightNatural)
    }

    private static func clamped(_ w: CGFloat) -> CGFloat { min(maxEar, max(minEar, w)) }

    /// Rendered width of the whole pill for a given notch gap.
    func width(notchWidth: CGFloat) -> CGFloat {
        left + right + notchWidth + 2 * (Theme.Space.edge + Theme.Space.md)
    }

    /// Distance from the pill's left edge to the center of the transparent gap.
    func gapCenter(notchWidth: CGFloat) -> CGFloat {
        Theme.Space.edge + left + Theme.Space.md + notchWidth / 2
    }

    /// How far to slide the pill so its gap sits on the window's center line — and so on
    /// the physical notch, since the window is centered on screen. Zero when the ears
    /// happen to match, which is why the old equal-width rule worked at all.
    var offsetX: CGFloat { (right - left) / 2 }
}

private struct LeftEarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RightEarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct StatusDot: View {
    let status: SessionStatus
    @State private var pulse = false
    @Environment(\.isMeasuringIsland) private var isMeasuring

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 7, height: 7)
            // A faint ring of the same hue keeps the dot from dissolving into the black.
            .overlay(Circle().stroke(status.color.opacity(0.35), lineWidth: 2.5))
            .shadow(color: status.color.opacity(0.7), radius: pulse ? 4 : 1)
            .scaleEffect(status == .working && pulse ? 1.15 : 1)
            .onAppear {
                if !isMeasuring, status == .working || status == .waiting {
                    withAnimation(Theme.Motion.breathe) { pulse = true }
                }
            }
    }
}

struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(Theme.Font.numeral(11, weight: .bold))
            .foregroundStyle(.black)
            .frame(minWidth: 16)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

/// A single dot with a soft expanding halo — a clear "live / working" pulse that reads as
/// activity rather than the old three-dot cluster, which looked like an overflow menu.
struct LivePulse: View {
    let color: Color
    @State private var animate = false
    @Environment(\.isMeasuringIsland) private var isMeasuring

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 7, height: 7)
                .scaleEffect(animate ? 2.4 : 1)
                .opacity(animate ? 0 : 0.55)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 15, height: 15)
        .onAppear {
            guard !isMeasuring else { return }
            withAnimation(Theme.Motion.halo) { animate = true }
        }
    }
}
