import SwiftUI

/// The expanded panel: header, then a scrollable list of every monitored session.
struct ExpandedIsland: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject var store: SessionStore

    private var panelWidth: CGFloat { max(440, notchWidth + 280) }

    var body: some View {
        VStack(spacing: 0) {
            notchBar           // occupies the physical-notch band; content only in the ears
            Divider().overlay(Color.white.opacity(0.06))
            sessionList
            footer
        }
        .frame(width: panelWidth)
        .background(
            NotchShape(bottomRadius: 26)
                .fill(.black)
        )
        .overlay(
            NotchShape(bottomRadius: 26)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .fixedSize()
    }

    /// The top band aligned with the physical notch: brand in the left ear, counts in
    /// the right ear, and an empty center gap the width of the notch.
    private var notchBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("🏝️").font(.system(size: 12))
                Text("CLAUDE ISLAND")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)

            Color.clear.frame(width: notchWidth)   // physical notch

            HStack(spacing: 6) {
                if store.attentionCount > 0 {
                    CountBadge(count: store.attentionCount, color: SessionStatus.waiting.color)
                }
                Text("\(store.sessions.count) agents")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
        }
        .frame(height: max(notchHeight, 32))
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.orderedSessions) { session in
                    SessionRow(session: session)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 340)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("Monitor", active: true)
            footerButton("Approve")
            footerButton("Ask")
            footerButton("Jump")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, active: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(active ? SessionStatus.done.color : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(active ? SessionStatus.done.color.opacity(0.5) : Color.white.opacity(0.08),
                            lineWidth: 0.5)
            )
            .padding(.horizontal, 2)
    }
}
