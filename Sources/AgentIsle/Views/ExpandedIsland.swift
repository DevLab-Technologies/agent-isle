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
                AppMark(size: 14)
                Text("AGENT ISLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)

            Color.clear.frame(width: notchWidth)   // physical notch

            HStack(spacing: 8) {
                if store.attentionCount > 0 {
                    CountBadge(count: store.attentionCount, color: SessionStatus.waiting.color)
                }
                Text("\(store.sessions.count) agents")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                settingsMenu
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
        }
        .frame(height: max(notchHeight, 32))
    }

    /// Gear menu — the reliable way to quit and toggle settings, since the menu-bar
    /// item can be hidden behind the notch on notched Macs.
    private var settingsMenu: some View {
        Menu {
            Button(SoundPlayer.shared.enabled ? "Mute Sound Alerts" : "Enable Sound Alerts") {
                SoundPlayer.shared.enabled.toggle()
            }
            Button(store.demoMode ? "Stop Demo Mode" : "Start Demo Mode") {
                store.demoMode ? store.stopDemo() : store.startDemo()
            }
            if HookInstaller.hasClaudeCode() {
                Divider()
                if HookInstaller.isInstalled() {
                    Button("Remove Claude Code Hooks") { HookInstaller.uninstall() }
                } else {
                    Button("Install Claude Code Hooks…") { HookInstaller.install() }
                }
            }
            Divider()
            Button("Quit Agent Isle") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 18)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if store.sessions.isEmpty {
                    welcomeState
                } else if store.visibleSessions.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    ForEach(store.visibleSessions) { session in
                        SessionRow(session: session)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 340)
    }

    /// Shown on a fresh install when nothing is running yet.
    private var welcomeState: some View {
        VStack(spacing: 10) {
            AppMark(size: 26)
            Text("Waiting for agents")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            Text("Start a Claude Code, Grok, or Copilot\nsession and it'll appear here.")
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.4))
            Button("Try demo mode") { store.startDemo() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SessionStatus.done.color)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var emptyMessage: String {
        switch store.filter {
        case .all: return "No active sessions"
        case .approve: return "Nothing waiting for approval"
        case .ask: return "No open questions"
        }
    }

    // Footer tabs filter the list. (Click a session row to jump to its terminal/IDE.)
    private var footer: some View {
        HStack(spacing: 0) {
            footerTab("Monitor", filter: .all)
            footerTab("Approve", filter: .approve, badge: store.sessions.filter { $0.status == .waiting }.count)
            footerTab("Ask", filter: .ask, badge: store.sessions.filter { $0.status == .asking }.count)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerTab(_ title: String, filter: SessionFilter, badge: Int = 0) -> some View {
        let active = isActive(filter)
        return Button {
            store.filter = filter
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(SessionStatus.waiting.color))
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(active ? SessionStatus.done.color : .white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? SessionStatus.done.color.opacity(0.12) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(active ? SessionStatus.done.color.opacity(0.5) : Color.white.opacity(0.08),
                            lineWidth: 0.5)
            )
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
    }

    private func isActive(_ f: SessionFilter) -> Bool {
        switch (store.filter, f) {
        case (.all, .all), (.approve, .approve), (.ask, .ask): return true
        default: return false
        }
    }
}
