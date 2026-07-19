import SwiftUI

/// The resting state: a slim black pill hugging the notch that surfaces the most
/// attention-worthy session plus a count badge.
struct CollapsedIsland: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject var store: SessionStore

    private var focus: AgentSession? { store.focusSession }

    private let earWidth: CGFloat = 148

    var body: some View {
        // Symmetric ears with a fixed center gap == the physical notch, so the gap
        // stays centered on screen (where the notch is) and text never hides behind it.
        HStack(spacing: 0) {
            leftCluster
                .frame(width: earWidth, alignment: .trailing)
                .padding(.trailing, 10)
            Color.clear
                .frame(width: notchWidth)   // the physical notch lives here
            rightCluster
                .frame(width: earWidth, alignment: .leading)
                .padding(.leading, 10)
        }
        .frame(height: max(notchHeight, 30))
        .background(
            NotchShape(bottomRadius: 16)
                .fill(.black)
        )
        .overlay(
            NotchShape(bottomRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder private var leftCluster: some View {
        if let s = focus {
            HStack(spacing: 6) {
                StatusDot(status: s.status)
                Text(s.agent.glyph)
                    .foregroundStyle(s.agent.tint)
                    .font(.system(size: 12))
                Text(s.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        } else {
            AppMark(size: 15)
        }
    }

    @ViewBuilder private var rightCluster: some View {
        HStack(spacing: 6) {
            if store.attentionCount > 0 {
                CountBadge(count: store.attentionCount, color: SessionStatus.waiting.color)
            } else if store.workingCount > 0 {
                WorkingIndicator()
            }
            Text("\(store.sessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
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

struct WorkingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 3, height: 3)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(i) * 0.7)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
