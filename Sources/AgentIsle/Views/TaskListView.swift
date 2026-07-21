import SwiftUI

/// Renders a session's task/todo list inside its card: a summary line with a slim
/// progress meter, then checkbox rows. Active and still-open items are always shown;
/// completed items fill the remaining space and any overflow collapses into a
/// "+N completed" footer, so a long list never blows out the compact panel.
struct TaskListView: View {
    let tasks: TaskList

    /// Most rows to show before collapsing the remainder into the footer.
    private let cap = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            summary
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible) { TaskRow(task: $0) }
            }
            if hiddenLabel != nil {
                Text(hiddenLabel!)
                    .font(Theme.Font.label(9.5))
                    .foregroundStyle(Theme.Ink.faint)
                    .padding(.leading, 21)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Fill.inset))
    }

    // MARK: - Summary + progress meter

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                Text("Tasks")
                    .font(Theme.Font.label(10, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
                Text(countLine)
                    .font(Theme.Font.label(9.5, weight: .regular))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(tasks.done)/\(tasks.total)")
                    .font(Theme.Font.label(9.5, weight: .semibold))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            progressMeter
        }
    }

    private var progressMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(SessionStatus.done.color)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
    }

    private var fraction: Double {
        tasks.total > 0 ? Double(tasks.done) / Double(tasks.total) : 0
    }

    /// "11 done · 1 in progress · 3 open" — zero segments are dropped, done is always shown.
    private var countLine: String {
        var parts = ["\(tasks.done) done"]
        if tasks.inProgress > 0 { parts.append("\(tasks.inProgress) in progress") }
        if tasks.open > 0 { parts.append("\(tasks.open) open") }
        return "· " + parts.joined(separator: " · ")
    }

    // MARK: - Visible / hidden split

    /// Actionable items first (in-progress, then open), then completed fill the rest.
    private var visible: [AgentTask] {
        let ordered = tasks.ordered
        let active = ordered.filter { $0.state != .completed }
        let completed = ordered.filter { $0.state == .completed }
        if active.count >= cap { return Array(active.prefix(cap)) }
        return active + completed.prefix(cap - active.count)
    }

    private var hiddenLabel: String? {
        let shown = visible.count
        let hidden = tasks.total - shown
        guard hidden > 0 else { return nil }
        // If everything hidden is completed, name it; otherwise a generic "+N more".
        let hiddenCompleted = tasks.done - visible.filter { $0.state == .completed }.count
        return hidden == hiddenCompleted ? "+\(hidden) completed" : "+\(hidden) more"
    }
}

/// One checkbox row: symbol tinted by state, text struck through when completed.
private struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: task.state.symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(task.state.color)
                .frame(width: 13)
            Text(task.text)
                .font(Theme.Font.body(10.5))
                .foregroundStyle(textColor)
                .strikethrough(task.state == .completed, color: Theme.Ink.faint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var textColor: Color {
        switch task.state {
        case .completed:  return Theme.Ink.faint
        case .inProgress: return Theme.Ink.primary
        case .pending:    return Theme.Ink.secondary
        }
    }
}
