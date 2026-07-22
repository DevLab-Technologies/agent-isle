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

            SettingsGroup(title: "Quiet Scenes",
                          footnote: "Automatically mute sound and notifications while you're in a Focus, your screen is locked, or your screen is being recorded. The island keeps updating — only the alerts are silenced.") {
                SettingsRow(title: "Enable Quiet Scenes",
                            subtitle: "Suppress alerts during do-not-disturb moments.",
                            showsDivider: settings.quietScenesEnabled) {
                    Toggle("", isOn: $settings.quietScenesEnabled).labelsHidden().toggleStyle(.switch)
                }
                if settings.quietScenesEnabled {
                    SettingsRow(title: "During Focus / Do Not Disturb") {
                        Toggle("", isOn: $settings.quietDuringFocus).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow(title: "When Screen Is Locked") {
                        Toggle("", isOn: $settings.quietWhenLocked).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsRow(title: "While Recording or Sharing Screen",
                                showsDivider: false) {
                        Toggle("", isOn: $settings.quietWhenScreenSharing).labelsHidden().toggleStyle(.switch)
                    }
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
    @EnvironmentObject var settings: AppSettings

    @State private var reports: [IntegrationDoctor.Report] = []
    @State private var serverReachable = false
    @State private var setupSummary: String?

    private var hookCapable: [CLIIntegration] { CLIIntegration.hookCapable }
    private var monitorOnly: [CLIIntegration] {
        CLIIntegration.all.filter { $0.hook == nil }
    }

    var body: some View {
        SettingsScaffold(section: .integrations) {
            hooksGroup
            setupGroup
            monitorGroup
            doctorGroup
        }
        .onAppear(perform: recheck)
    }

    // MARK: Hooks

    private var hooksGroup: some View {
        SettingsGroup(title: "CLI Hooks",
                      footnote: "Hooks let a CLI push permission and completion events to the island in real time, so you can approve tool calls straight from the notch.") {
            ForEach(Array(hookCapable.enumerated()), id: \.element.id) { idx, integration in
                let installed = integration.hook?.isInstalled() ?? false
                SettingsRow(title: integration.displayName,
                            subtitle: integration.hasCLI() ? nil : "Not found in \(integration.configDir.path).",
                            showsDivider: idx < hookCapable.count - 1) {
                    if integration.hasCLI() {
                        HStack(spacing: 8) {
                            StatusText(active: installed)
                            Toggle("", isOn: Binding(
                                get: { installed },
                                set: { on in
                                    _ = on ? integration.hook?.install() : integration.hook?.uninstall()
                                    recheck()
                                }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    } else {
                        Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Zero-config setup

    private var setupGroup: some View {
        SettingsGroup(title: "Setup",
                      footnote: setupSummary ?? "Detect every installed CLI and install its hook in one step.") {
            SettingsRow(title: "Set up integrations",
                        subtitle: "Scan for supported CLIs and configure any that aren't set up yet.") {
                Button("Re-scan", action: runSetup)
            }
            SettingsRow(title: "Automatic setup",
                        subtitle: "Configure detected CLIs on first launch and offer to finish any that are missing.",
                        showsDivider: false) {
                Toggle("", isOn: $settings.autoSetupIntegrations).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: Monitor-only agents

    @ViewBuilder private var monitorGroup: some View {
        let detected = monitorOnly.filter { $0.hasCLI() }
        if !detected.isEmpty {
            SettingsGroup(title: "Monitored agents",
                          footnote: "These CLIs have no hook mechanism, so Agent Isle reads their activity from history. They appear automatically when active.") {
                ForEach(Array(detected.enumerated()), id: \.element.id) { idx, integration in
                    SettingsRow(title: integration.displayName,
                                showsDivider: idx < detected.count - 1) {
                        HStack(spacing: 6) {
                            AgentBadge(agent: integration.agent, size: 20)
                            Text(integration.monitorLabel)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Doctor

    private var doctorGroup: some View {
        SettingsGroup(title: "Integration Doctor",
                      footnote: "Checks each integration end-to-end: CLI present, hook installed and pointing at the right port, event server reachable, and history readable.") {
            SettingsRow(title: "Event server",
                        subtitle: "Listening on localhost:\(EventServer.port) for CLI events.",
                        showsDivider: !reports.isEmpty) {
                HStack(spacing: 8) {
                    DoctorBadge(status: serverReachable ? .ok : .fail)
                    Button("Re-check", action: recheck)
                }
            }
            ForEach(Array(reports.enumerated()), id: \.element.id) { idx, report in
                DoctorRow(report: report,
                          showsDivider: idx < reports.count - 1,
                          onFix: { fix(report.agent) })
            }
        }
    }

    // MARK: Actions

    private func recheck() {
        serverReachable = IntegrationDoctor.serverReachable()
        reports = IntegrationDoctor.run()
    }

    private func runSetup() {
        let pending = hookCapable.filter { $0.hasCLI() && !($0.hook?.isInstalled() ?? true) }
        let installed = pending.filter { $0.hook?.install() ?? false }
        setupSummary = installed.isEmpty
            ? (hookCapable.contains { $0.hasCLI() } ? "All detected CLIs are already set up."
                                                    : "No supported CLIs detected yet.")
            : "Configured \(installed.map(\.displayName).joined(separator: ", ")). Restart those sessions to apply."
        recheck()
    }

    private func fix(_ agent: AgentKind) {
        _ = IntegrationDoctor.fix(agent)
        recheck()
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

/// A colored SF-Symbol dot for a doctor status.
private struct DoctorBadge: View {
    let status: IntegrationDoctor.Status
    var body: some View {
        Image(systemName: symbol).foregroundStyle(color).font(.system(size: 13, weight: .medium))
    }
    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }
    private var color: Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return Palette.deny
        case .info: return .secondary
        }
    }
}

/// One integration's expandable health summary with an optional one-click Fix.
private struct DoctorRow: View {
    let report: IntegrationDoctor.Report
    var showsDivider: Bool = true
    let onFix: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text(report.displayName).font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                if report.fixable {
                    Button("Fix", action: onFix)
                }
                DoctorBadge(status: report.overall)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.checks) { check in
                        HStack(alignment: .top, spacing: 8) {
                            DoctorBadge(status: check.status)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.title).font(.system(size: 12, weight: .medium))
                                Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsDivider { Divider().padding(.leading, 14) }
        }
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

            SettingsGroup(title: "Behavior",
                          footnote: "Fullscreen hiding affects only the notch island. Smart suppression still plays the sound cue and posts the notification — it only skips popping the panel open.") {
                SettingsRow(title: "Hide in Fullscreen",
                            subtitle: "Hide the notch island while a fullscreen window is frontmost.") {
                    Toggle("", isOn: $settings.hideInFullscreen).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Auto-expand on Attention",
                            subtitle: "Open the panel automatically when a session needs a permission or asks a question.") {
                    Toggle("", isOn: $settings.autoExpandOnAttention).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Smart Suppression",
                            subtitle: "When auto-expand is on, skip it for a session whose terminal is already frontmost.",
                            showsDivider: false) {
                    Toggle("", isOn: $settings.smartSuppression).labelsHidden().toggleStyle(.switch)
                        .disabled(!settings.autoExpandOnAttention)
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
                SettingsRow(title: "Show Terminal") {
                    Toggle("", isOn: $settings.showTerminal).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Show Usage Readout",
                            subtitle: "Compact rolling-window usage (5h / 7d) for the focused agent, in the expanded header.",
                            showsDivider: false) {
                    Toggle("", isOn: $settings.showUsageReadout).labelsHidden().toggleStyle(.switch)
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
