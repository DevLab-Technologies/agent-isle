import SwiftUI

/// One session in the expanded list: agent badge, title, live message, and — when
/// the agent needs the user — an inline permission or question card.
struct SessionRow: View {
    let session: AgentSession
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if let permission = session.permission {
                PermissionCard(session: session, request: permission)
            }
            if let question = session.question {
                QuestionCard(session: session, question: question)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: needsAttention ? 1 : 0.5)
        )
    }

    private var needsAttention: Bool {
        session.status == .waiting || session.status == .asking
    }

    private var borderColor: Color {
        needsAttention ? session.status.color.opacity(0.5) : Color.white.opacity(0.06)
    }

    private var headerRow: some View {
        HStack(spacing: 9) {
            AgentBadge(agent: session.agent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    Text(session.agent.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(session.agent.tint.opacity(0.9))
                    Text("·").foregroundStyle(.white.opacity(0.25))
                    Text(session.terminal)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    if store.demoMode {
                        Text("DEMO")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }
                Text(session.lastMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                StatusPill(status: session.status)
                HStack(spacing: 5) {
                    if let tok = session.tokenText {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .font(.system(size: 7))
                            Text(tok)
                        }
                        .foregroundStyle(.white.opacity(0.4))
                    }
                    Text(session.elapsedText)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Click a session to open its live chat (jump lives inside the chat header).
            store.openChat(session)
        }
    }
}

struct AgentBadge: View {
    let agent: AgentKind
    var body: some View {
        Text(agent.glyph)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(agent.tint)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(agent.tint.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(agent.tint.opacity(0.35), lineWidth: 0.5)
            )
    }
}

struct StatusPill: View {
    let status: SessionStatus
    var body: some View {
        HStack(spacing: 4) {
            StatusDot(status: status)
            Text(status.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.12)))
    }
}
