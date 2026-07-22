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

    /// Wider ears so the session title has real room before it truncates (the old 148
    /// clipped most repo·branch titles after ~14 chars).
    private let earWidth: CGFloat = 176

    /// Color of the "needs you" signal — amber for a pending permission, purple for a
    /// question, teal for a plan review, matching the per-status colors used elsewhere.
    /// Ordered by urgency so the most blocking state wins when several are pending.
    private var attentionColor: Color {
        if store.visibleSessions.contains(where: { $0.status == .waiting }) { return SessionStatus.waiting.color }
        if store.visibleSessions.contains(where: { $0.status == .asking }) { return SessionStatus.asking.color }
        return SessionStatus.planning.color
    }

    var body: some View {
        // Symmetric ears with a fixed center gap == the physical notch, so the gap
        // stays centered on screen (where the notch is) and text never hides behind it.
        HStack(spacing: 0) {
            leftCluster
                .frame(width: earWidth, alignment: .trailing)
                .padding(.trailing, Theme.Space.md)
            Color.clear
                .frame(width: notchWidth)   // the physical notch lives here
            rightCluster
                .frame(width: earWidth, alignment: .leading)
                .padding(.leading, Theme.Space.md)
        }
        .frame(height: max(notchHeight, 30))
        .background(
            NotchShape(bottomRadius: 16)
                .fill(.black)
        )
        .overlay(
            NotchShape(bottomRadius: 16)
                .stroke(Theme.Fill.hairline, lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder private var leftCluster: some View {
        if let s = focus {
            HStack(spacing: Theme.Space.sm) {
                StatusDot(status: s.status)
                Text(s.agent.glyph)
                    .font(.system(size: 11))
                    .foregroundStyle(s.agent.tint)
                Text(s.title)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
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
    @ViewBuilder private var rightCluster: some View {
        HStack(spacing: Theme.Space.sm) {
            if store.attentionCount > 0 {
                CountBadge(count: store.attentionCount, color: attentionColor)
            } else if store.workingCount > 0 {
                LivePulse(color: SessionStatus.working.color)
            }
            // How many sub-agents the surfaced session is running, right by the pulse.
            if settings.showSubAgents, workingSubAgents > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(workingSubAgents)")
                        .font(Theme.Font.label(9.5, weight: .semibold))
                }
                .foregroundStyle(SessionStatus.working.color)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(SessionStatus.working.color.opacity(0.14)))
            }
            if store.visibleSessions.count > 1 {
                Text("\(store.visibleSessions.count)")
                    .font(Theme.Font.label(10.5, weight: .semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .padding(.horizontal, Theme.Space.sm).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Fill.card))
                    .overlay(Capsule().stroke(Theme.Fill.hairline, lineWidth: 0.5))
            }
        }
    }
}

struct StatusDot: View {
    let status: SessionStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 7, height: 7)
            .shadow(color: status.color.opacity(0.7), radius: pulse ? 4 : 1)
            .scaleEffect(status == .working && pulse ? 1.25 : 1)
            .onAppear {
                if status == .working || status == .waiting {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            }
    }
}

struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
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

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 7, height: 7)
                .scaleEffect(animate ? 2.1 : 1)
                .opacity(animate ? 0 : 0.6)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 15, height: 15)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}
