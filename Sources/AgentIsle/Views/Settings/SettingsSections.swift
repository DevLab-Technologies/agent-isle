import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        SettingsScaffold(section: .general) {
            SettingsGroup(title: "System",
                          footnote: launchFailed ? "Launch at Login needs a signed, installed app; it can't be set from a dev build." : nil) {
                SettingsRow(title: "Launch at Login",
                            subtitle: "Start Agent Isle automatically when you log in.",
                            showsDivider: false) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if !LaunchAtLogin.setEnabled(newValue) {
                                launchFailed = true
                                launchAtLogin = LaunchAtLogin.isEnabled  // revert to real state
                            } else {
                                launchFailed = false
                            }
                        }
                }
            }

            SettingsGroup(title: "Notifications",
                          footnote: "System banners for permission requests, questions, and completions. Permission banners include Allow and Deny buttons.") {
                SettingsRow(title: "Enable Notifications",
                            subtitle: "Post a macOS banner when a session needs attention or finishes.",
                            showsDivider: false) {
                    Toggle("", isOn: $settings.notificationsEnabled).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Behavior") {
                SettingsRow(title: "Demo Mode",
                            subtitle: "Show simulated sessions to preview the island.") {
                    Toggle("", isOn: Binding(
                        get: { store.demoMode },
                        set: { $0 ? store.startDemo() : store.stopDemo() }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    @State private var launchFailed = false
}

// MARK: - Integrations

struct IntegrationsSettings: View {
    @State private var claudeInstalled = HookInstaller.isInstalled()
    @State private var cursorInstalled = CursorHookInstaller.isInstalled()
    private let hasClaude = HookInstaller.hasClaudeCode()
    private let hasCursor = CursorHookInstaller.hasCursor()

    // Agents discovered from their own history files (no hook required).
    private let autoDetected: [AgentKind] = [.cursor, .grok, .copilot]

    var body: some View {
        SettingsScaffold(section: .integrations) {
            SettingsGroup(title: "CLI Hooks",
                          footnote: "Hooks let a CLI push permission and completion events to the island in real time, so you can approve tool calls straight from the notch.") {
                SettingsRow(title: "Claude Code",
                            subtitle: hasClaude ? nil : "Claude Code not found in ~/.claude.") {
                    if hasClaude {
                        HStack(spacing: 8) {
                            StatusText(active: claudeInstalled)
                            Toggle("", isOn: Binding(
                                get: { claudeInstalled },
                                set: { on in
                                    _ = on ? HookInstaller.install() : HookInstaller.uninstall()
                                    claudeInstalled = HookInstaller.isInstalled()
                                }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    } else {
                        Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                SettingsRow(title: "Cursor",
                            subtitle: hasCursor ? nil : "Cursor not found in ~/.cursor.",
                            showsDivider: false) {
                    if hasCursor {
                        HStack(spacing: 8) {
                            StatusText(active: cursorInstalled)
                            Toggle("", isOn: Binding(
                                get: { cursorInstalled },
                                set: { on in
                                    _ = on ? CursorHookInstaller.install() : CursorHookInstaller.uninstall()
                                    cursorInstalled = CursorHookInstaller.isInstalled()
                                }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    } else {
                        Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: "Auto-detected agents",
                          footnote: "These are discovered from their own history files — no hook needed. They appear automatically when active.") {
                ForEach(Array(autoDetected.enumerated()), id: \.offset) { idx, agent in
                    SettingsRow(title: agent.displayName,
                                showsDivider: idx < autoDetected.count - 1) {
                        HStack(spacing: 6) {
                            AgentBadge(agent: agent, size: 20)
                            Text(ChatHistory.isSupported(agent) ? "Live chat" : "Monitor only")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct StatusText: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? .green : .secondary)
            Text(active ? "Active" : "Off").foregroundStyle(active ? .green : .secondary)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

// MARK: - Display

struct DisplaySettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsScaffold(section: .display) {
            SettingsGroup(title: "Surface",
                          footnote: "Notch shows the island over the notch (or a centered pill). Menu Bar opens the full session panel from the menu-bar icon — best for Macs without a notch or on external displays. Both shows the island and the menu-bar panel together.") {
                SettingsRow(title: "Display Mode",
                            subtitle: "Where Agent Isle shows your sessions.",
                            showsDivider: false) {
                    Picker("", selection: $settings.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
            }

            SettingsGroup(title: "Session Card") {
                SettingsRow(title: "Show Task List",
                            subtitle: "Render the agent's todo list with progress.") {
                    Toggle("", isOn: $settings.showTasks).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Token Count") {
                    Toggle("", isOn: $settings.showTokens).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Model",
                            subtitle: "Display the model each session is running, e.g. Opus 4.8.") {
                    Toggle("", isOn: $settings.showModel).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Sub-agents",
                            subtitle: "List the background sub-agents a session spawned and their progress.") {
                    Toggle("", isOn: $settings.showSubAgents).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Terminal", showsDivider: false) {
                    Toggle("", isOn: $settings.showTerminal).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Panel Size") {
                SliderRow(title: "Max Panel Width", value: $settings.maxPanelWidth,
                          range: 440...800, step: 10, unit: "pt")
                SliderRow(title: "Max Panel Height", value: $settings.maxPanelHeight,
                          range: 240...600, step: 10, unit: "pt", showsDivider: false)
            }

            SettingsGroup(title: "Notch Tuning",
                          footnote: "Fine-tune if the island doesn't line up with your notch. 0 uses the macOS value.") {
                SliderRow(title: "Notch Width Offset", value: $settings.notchWidthAdjust,
                          range: -60...60, step: 2, unit: "pt")
                SliderRow(title: "Notch Height Offset", value: $settings.notchHeightAdjust,
                          range: -12...24, step: 1, unit: "pt", showsDivider: false)
            }
        }
    }
}

/// A labeled slider row with a live value readout.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var showsDivider: Bool = true

    var body: some View {
        SettingsRow(title: title, showsDivider: showsDivider) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(width: 220)
                Text("\(Int(value))\(unit)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

// MARK: - Sound

struct SoundSettings: View {
    @EnvironmentObject var settings: AppSettings

    private let previews: [(String, SoundPlayer.Event)] = [
        ("Attention", .attention), ("Approve", .approve), ("Deny", .deny),
        ("Select", .select), ("Done", .done),
    ]

    var body: some View {
        SettingsScaffold(section: .sound) {
            SettingsGroup(title: "Output") {
                SettingsRow(title: "Enable Sound Effects",
                            subtitle: "Chiptune cues for approvals, questions, and completions.") {
                    Toggle("", isOn: $settings.soundEnabled).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Volume", showsDivider: false) {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1).frame(width: 200)
                            .disabled(!settings.soundEnabled)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(Int(settings.soundVolume * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            SettingsGroup(title: "Preview",
                          footnote: "Tap to hear each cue.") {
                let cols = [GridItem(.adaptive(minimum: 110), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { _, item in
                        Button {
                            let wasEnabled = SoundPlayer.shared.enabled
                            SoundPlayer.shared.enabled = true          // always audible for preview
                            SoundPlayer.shared.play(item.1)
                            SoundPlayer.shared.enabled = wasEnabled
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                Text(item.0).font(.system(size: 12))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    private let repoURL = URL(string: "https://github.com/DevLab-Technologies/agent-isle")!
    private let issuesURL = URL(string: "https://github.com/DevLab-Technologies/agent-isle/issues")!
    @State private var reportingProblem = false

    var body: some View {
        SettingsScaffold(section: .about) {
            VStack(spacing: 8) {
                AppMark(size: 52)
                Text("Agent Isle").font(.system(size: 18, weight: .bold))
                Text("Version \(ProblemReport.appVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            SettingsGroup(title: "Updates") {
                SettingsRow(title: "Check for Updates…") {
                    Button("Check Now") { Updater.shared.checkForUpdates(userInitiated: true) }
                }
                SettingsRow(title: "Install Updates Automatically",
                            subtitle: "Download and apply new releases in the background.",
                            showsDivider: false) {
                    Toggle("", isOn: Binding(
                        get: { Updater.shared.autoInstall },
                        set: { Updater.shared.autoInstall = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Feedback") {
                SettingsRow(title: "Report a Problem",
                            subtitle: "Compose a bug report with diagnostics attached.") {
                    Button("Report…") { reportingProblem = true }
                }
                LinkRow(title: "Browse Issues", value: "GitHub Issues", url: issuesURL, showsDivider: false)
            }

            SettingsGroup(title: "Links") {
                LinkRow(title: "Source Code", value: "GitHub", url: repoURL, showsDivider: false)
            }

            Button(role: .destructive) { NSApp.terminate(nil) } label: {
                Text("Quit Agent Isle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .sheet(isPresented: $reportingProblem) { ReportProblemView() }
    }
}

private struct LinkRow: View {
    let title: String
    let value: String
    let url: URL
    var showsDivider: Bool = true
    var body: some View {
        SettingsRow(title: title, showsDivider: showsDivider) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    Text(value).font(.system(size: 12))
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
    }
}
