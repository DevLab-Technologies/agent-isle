import AppKit
import SwiftUI

/// A compact, keyboard-driven session switcher shown by the global hotkey.
///
/// Sessions are listed the same way the collapsed island prioritizes them — the ones
/// needing attention (waiting / asking) first. Arrow keys or number keys move the
/// selection, Return jumps to the selected session's terminal/IDE (reusing `Jumper`),
/// and Esc dismisses without doing anything.
struct SwitcherView: View {
    @ObservedObject var store: SessionStore
    /// Jump to a session and close the switcher.
    let onSelect: (AgentSession) -> Void
    /// Close the switcher without acting.
    let onDismiss: () -> Void

    @State private var selected = 0
    @FocusState private var focused: Bool

    private var sessions: [AgentSession] { store.orderedSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Fill.hairline)
            if sessions.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { commit(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let n = Int(press.characters), n >= 1, n <= min(9, sessions.count)
            else { return .ignored }
            selected = n - 1
            return .handled
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 15)
            Text("SWITCH SESSION")
                .font(Theme.Font.label(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.Ink.primary)
            Spacer(minLength: 4)
            Text("↑↓ select · ↩ jump · esc")
                .font(Theme.Font.label(9, weight: .regular))
                .foregroundStyle(Theme.Ink.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                        row(index: idx, session: session)
                            .id(session.id)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)
            .onChange(of: selected) { _, new in
                guard sessions.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(sessions[new].id, anchor: .center)
                }
            }
        }
    }

    private func row(index: Int, session: AgentSession) -> some View {
        let isSelected = index == selected
        return Button {
            selected = index
            commit()
        } label: {
            HStack(spacing: 10) {
                AgentBadge(agent: session.agent, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(Theme.Font.title(12))
                        .foregroundStyle(Theme.Ink.primary)
                        .lineLimit(1)
                    Text(session.lastMessage)
                        .font(Theme.Font.body(10))
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusPill(status: session.status)
                if index < 9 {
                    Text("\(index + 1)")
                        .font(Theme.Font.label(10, weight: .bold))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isSelected ? session.status.color.opacity(0.18) : Theme.Fill.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(isSelected ? session.status.color.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Text("No active sessions")
            .font(Theme.Font.body(11))
            .foregroundStyle(Theme.Ink.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func move(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        selected = min(max(selected + delta, 0), sessions.count - 1)
    }

    private func commit() {
        guard sessions.indices.contains(selected) else { return }
        onSelect(sessions[selected])
    }
}

/// A borderless floating panel that can become key (a plain borderless `NSPanel` can't),
/// so the switcher receives keyboard input. Dismisses itself when it loses key status.
final class SwitcherPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Esc is also handled by the SwiftUI view, but a borderless panel routes an
    /// unhandled Escape here as `cancelOperation`; close on it as a safety net.
    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }
}
