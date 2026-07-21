import SwiftUI

/// Renders a session's active background sub-agents (Claude Code's `Task` tool) inside its
/// card: a header with the count of how many are working, then one row per sub-agent
/// showing its task and latest activity. A session orchestrating sub-agents otherwise looks
/// idle — this is where their progress shows up.
struct SubAgentListView: View {
    let subAgents: [SubAgent]

    /// Most rows before the remainder collapses into a footer.
    private let cap = 6

    private var workingCount: Int { subAgents.filter(\.working).count }

    /// Working ones first, then most recently updated.
    private var ordered: [SubAgent] {
        subAgents.sorted { a, b in
            a.working != b.working ? a.working : a.updatedAt > b.updatedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            VStack(alignment: .leading, spacing: 7) {
                ForEach(ordered.prefix(cap)) { SubAgentRow(agent: $0) }
            }
            if subAgents.count > cap {
                Text("+\(subAgents.count - cap) more")
                    .font(Theme.Font.label(9.5))
                    .foregroundStyle(Theme.Ink.faint)
                    .padding(.leading, 18)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Fill.inset))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.Ink.secondary)
            Text("Sub-agents")
                .font(Theme.Font.label(10, weight: .semibold))
                .foregroundStyle(Theme.Ink.primary)
            Spacer(minLength: 0)
            Text(workingCount > 0 ? "\(workingCount) working" : "\(subAgents.count) done")
                .font(Theme.Font.label(9.5, weight: .regular))
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}

/// One sub-agent: a status dot, its task, and a dimmer line of what it's doing now.
private struct SubAgentRow: View {
    let agent: SubAgent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title)
                    .font(Theme.Font.label(10, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(agent.lastMessage)
                    .font(Theme.Font.body(9.5))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private var dotColor: Color {
        agent.working ? SessionStatus.working.color : Theme.Ink.faint
    }
}
