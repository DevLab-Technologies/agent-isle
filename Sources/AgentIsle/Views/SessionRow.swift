import SwiftUI

/// One session in the expanded list: agent identity, live activity, task progress, and —
/// when the agent needs the user — an inline permission or question card.
struct SessionRow: View {
    let session: AgentSession
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            identity
            if settings.showTasks, !session.tasks.isEmpty {
                TaskListView(tasks: session.tasks)
            }
            if let permission = session.permission {
                PermissionCard(session: session, request: permission)
            }
            if let question = session.question {
                // Key by the question so a superseding prompt resets the card's
                // selection/other-text state instead of carrying stale choices over.
                QuestionCard(session: session, question: question)
                    .id(question)
            }
        }
        .padding(Theme.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(needsAttention ? session.status.color.opacity(0.06) : Theme.Fill.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(borderColor, lineWidth: needsAttention ? 1 : 0.5)
        )
    }

    private var needsAttention: Bool {
        session.status == .waiting || session.status == .asking
    }

    private var borderColor: Color {
        needsAttention ? session.status.color.opacity(0.5) : Theme.Fill.hairline
    }

    // MARK: - Identity block (tappable — opens the live chat)

    private var identity: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            AgentBadge(agent: session.agent, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                // Title + agent tag + elapsed, mirroring a native message header.
                HStack(spacing: Theme.Space.sm) {
                    Text(session.title)
                        .font(Theme.Font.title(12.5))
                        .foregroundStyle(Theme.Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    AgentTag(agent: session.agent)
                    if store.demoMode {
                        Text("DEMO")
                            .font(Theme.Font.label(8, weight: .bold))
                            .foregroundStyle(Theme.Ink.tertiary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    Text(session.elapsedText)
                        .font(Theme.Font.label(9.5, weight: .regular))
                        .foregroundStyle(Theme.Ink.faint)
                }
                Text(session.lastMessage)
                    .font(Theme.Font.body(10.5))
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                // Status + terminal + token meter, the calm bottom line.
                HStack(spacing: Theme.Space.sm) {
                    StatusPill(status: session.status)
                    if settings.showTerminal {
                        Text(session.terminal)
                            .font(Theme.Font.label(9.5, weight: .regular))
                            .foregroundStyle(Theme.Ink.tertiary)
                    }
                    if settings.showTokens, let tok = session.tokenText {
                        HStack(spacing: 3) {
                            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 7))
                            Text(tok)
                        }
                        .font(Theme.Font.label(9.5, weight: .regular))
                        .foregroundStyle(Theme.Ink.faint)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openChat(session) }
    }
}

/// The compact agent mark — a tinted rounded tile with the agent's glyph.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 28
    var body: some View {
        Text(agent.glyph)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(agent.tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3)
                    .fill(agent.tint.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3)
                    .stroke(agent.tint.opacity(0.35), lineWidth: 0.5)
            )
    }
}

/// The agent-name pill (e.g. "Claude"), tinted to the agent's accent — the competitor's
/// most recognizable identity cue.
struct AgentTag: View {
    let agent: AgentKind
    var body: some View {
        Text(agent.displayName)
            .font(Theme.Font.label(9, weight: .semibold))
            .foregroundStyle(agent.tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(agent.tint.opacity(0.15)))
            .overlay(Capsule().stroke(agent.tint.opacity(0.3), lineWidth: 0.5))
            .fixedSize()
    }
}

struct StatusPill: View {
    let status: SessionStatus
    var body: some View {
        HStack(spacing: 4) {
            StatusDot(status: status)
            Text(status.label)
                .font(Theme.Font.label(9, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(status.color.opacity(0.12)))
    }
}
