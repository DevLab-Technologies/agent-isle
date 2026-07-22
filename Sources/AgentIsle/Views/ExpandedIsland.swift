import SwiftUI

/// The expanded panel: header, then a scrollable list of every monitored session.
struct ExpandedIsland: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var usage = UsageStore.shared

    private var panelWidth: CGFloat { max(440, CGFloat(settings.maxPanelWidth)) }

    var body: some View {
        VStack(spacing: 0) {
            notchBar           // occupies the physical-notch band; content only in the ears
            Divider().overlay(Theme.Fill.hairline)
            usageReadoutBar
            if let session = store.openedSession {
                SessionChatView(session: session)
            } else {
                sessionList
            }
        }
        .frame(width: panelWidth)
        .task { await usage.refresh() }   // warm the rolling-window readout when the panel opens
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
        .background(panelHotkeys)
    }

    /// Panel-wide shortcuts, active while the expanded island is the key window: Esc
    /// collapses (closing an open chat first), ⌘J jumps to the focused session. Hidden
    /// zero-size buttons so the chords register without occupying layout.
    private var panelHotkeys: some View {
        ZStack {
            Button("", action: collapse)
                .keyboardShortcut(.cancelAction)
            Button("", action: jumpToFocused)
                .keyboardShortcut("j", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func collapse() {
        if store.openedSessionID != nil { store.closeChat() }
        store.isExpanded = false
    }

    private func jumpToFocused() {
        guard let target = store.openedSession ?? store.focusSession else { return }
        Jumper.jump(to: target)
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
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)

            Color.clear.frame(width: notchWidth)   // physical notch

            HStack(spacing: 8) {
                if store.attentionCount > 0 {
                    CountBadge(count: store.attentionCount, color: SessionStatus.waiting.color)
                }
                Text("\(store.sessions.count) \(store.sessions.count == 1 ? "agent" : "agents")")
                    .font(Theme.Font.label(10))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(1)
                settingsMenu
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
        }
        .frame(height: max(notchHeight, 32))
    }

    /// Compact rolling-usage readout for the focused session's agent, e.g.
    /// "5h 62% · 7d 41%" (cap known) or "5h 1.2M · 7d 4.8M" (no cap). Hidden when the
    /// toggle is off, no session is focused, or that agent has no window data yet.
    @ViewBuilder private var usageReadoutBar: some View {
        if settings.showUsageReadout,
           let agent = (store.openedSession ?? store.focusSession)?.agent,
           let readout = usage.windowUsage(for: agent) {
            HStack(spacing: 6) {
                Circle().fill(agent.tint).frame(width: 6, height: 6)
                Text(agent.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Ink.tertiary)
                Text(readout.compact)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !readout.hasKnownCap {
                    Text("no cap")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 5)
            Divider().overlay(Theme.Fill.hairline)
        }
    }

    /// Gear menu — the reliable way to quit and toggle settings, since the menu-bar
    /// item can be hidden behind the notch on notched Macs.
    private var settingsMenu: some View {
        Menu {
            Button("Settings…") {
                NotificationCenter.default.post(name: .openAgentIsleSettings, object: nil)
            }
            Divider()
            Button(store.demoMode ? "Stop Demo Mode" : "Start Demo Mode") {
                store.demoMode ? store.stopDemo() : store.startDemo()
            }
            Toggle("Sound Alerts", isOn: $settings.soundEnabled)
            if HookInstaller.hasClaudeCode() {
                Divider()
                if HookInstaller.isInstalled() {
                    Button("Remove Claude Code Hooks") { HookInstaller.uninstall() }
                } else {
                    Button("Install Claude Code Hooks…") { HookInstaller.install() }
                }
                Button("Copy Claude Code Hook Command") { copyHookCommand() }
            }
            if CursorHookInstaller.hasCursor() {
                if !HookInstaller.hasClaudeCode() { Divider() }
                if CursorHookInstaller.isInstalled() {
                    Button("Remove Cursor Hooks") { CursorHookInstaller.uninstall() }
                } else {
                    Button("Install Cursor Hooks…") { CursorHookInstaller.install() }
                }
            }
            Divider()
            Button("Check for Updates…") { Updater.shared.checkForUpdates(userInitiated: true) }
            Toggle("Automatically Install Updates", isOn: Binding(
                get: { Updater.shared.autoInstall },
                set: { Updater.shared.autoInstall = $0 }))
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

    /// Put the curl one-liner agents can POST events to on the pasteboard (mirrors the
    /// menu-bar item's old "Copy Hook Command").
    private func copyHookCommand() {
        let cmd = "curl -s -X POST http://localhost:\(EventServer.port)/event " +
                  "-H 'Content-Type: application/json' -d @-"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                if store.sessions.isEmpty {
                    welcomeState
                } else {
                    ForEach(store.orderedSessions) { session in
                        SessionRow(session: session)
                    }
                }
            }
            .padding(Theme.Space.lg)
        }
        .frame(maxHeight: CGFloat(settings.maxPanelHeight))
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

}
