import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

            SettingsGroup(title: "Stability",
                          footnote: "A safety net for long uptimes: if Agent Isle's memory stays unusually high, it relaunches itself in the background. It never restarts while a session is waiting on you. Off by default.") {
                SettingsRow(title: "Restart on High Memory",
                            subtitle: "Automatically relaunch if memory use stays above a safe limit.",
                            showsDivider: false) {
                    Toggle("", isOn: $settings.autoRestartOnHighMemory).labelsHidden().toggleStyle(.switch)
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
                            subtitle: "Where Agent Isle shows your sessions.") {
                    Picker("", selection: $settings.displayMode) {
                        ForEach(DisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                SettingsRow(title: "Collapsed Style",
                            subtitle: "Detailed shows status, agent, and live activity; Clean shows just the focused title and count.",
                            showsDivider: false) {
                    Picker("", selection: $settings.collapsedStyle) {
                        ForEach(CollapsedStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
            }

            SettingsGroup(title: "Behavior",
                          footnote: "Fullscreen hiding and auto-hide affect only the notch island. Smart suppression still plays the sound cue and posts the notification — it only skips popping the panel open.") {
                SettingsRow(title: "Hide in Fullscreen",
                            subtitle: "Hide the notch island while a fullscreen window is frontmost.") {
                    Toggle("", isOn: $settings.hideInFullscreen).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Auto-hide When Empty",
                            subtitle: "Hide the notch island when no session is active, and show it again when one appears.") {
                    Toggle("", isOn: $settings.autoHideWhenEmpty).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Click to Open Session",
                            subtitle: "Tap a session card to open its live conversation. Turn off to make cards non-interactive.") {
                    Toggle("", isOn: $settings.clickToJump).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "Expand on Hover",
                            subtitle: "Expand the island while the pointer rests over it.") {
                    Toggle("", isOn: $settings.expandOnHover).labelsHidden().toggleStyle(.switch)
                }
                SliderRow(title: "Hover-expand Delay",
                          subtitle: "How long the pointer must rest before the island expands.",
                          value: $settings.hoverExpandDelay,
                          range: 0...1.0, step: 0.05, unit: "s", decimals: 2,
                          disabled: !settings.expandOnHover)
                SliderRow(title: "Auto-collapse Delay",
                          subtitle: "How long the island lingers after the pointer leaves before collapsing.",
                          value: $settings.autoCollapseDelay,
                          range: 0...5, step: 0.1, unit: "s", decimals: 1,
                          disabled: !settings.expandOnHover)
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

            SettingsGroup(title: "Sessions",
                          footnote: "How long a quiet session stays on the island before it's cleared. Lower values tidy up finished work sooner; you can also dismiss a finished session by hand from its row.") {
                SliderRow(title: "Idle Cleanup", value: $settings.idleCleanupMinutes,
                          range: 1...60, step: 1, unit: "m", showsDivider: false)
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
    var subtitle: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    /// Decimal places in the readout; 0 renders an integer (e.g. "480pt"), 1 a tenth
    /// (e.g. "0.5s") for the sub-second timing sliders.
    var decimals: Int = 0
    var disabled: Bool = false
    var showsDivider: Bool = true

    private var readout: String {
        decimals > 0 ? String(format: "%.\(decimals)f\(unit)", value) : "\(Int(value))\(unit)"
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, showsDivider: showsDivider) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(width: 220).disabled(disabled)
                Text(readout)
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

    private let events = SoundPlayer.Event.allCases

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

            SettingsGroup(title: "Sound Pack",
                          footnote: "Replace any cue with your own audio (.wav, .aiff, .mp3). Cues without a custom file use the built-in chiptune sound. Tap play to preview.") {
                ForEach(Array(events.enumerated()), id: \.element) { idx, event in
                    CustomSoundRow(event: event,
                                   showsDivider: idx < events.count - 1)
                        .environmentObject(settings)
                }
            }
        }
    }
}

/// One sound event: a play/preview button, the current source (custom filename or the
/// built-in cue), and Import / Clear controls.
private struct CustomSoundRow: View {
    @EnvironmentObject var settings: AppSettings
    let event: SoundPlayer.Event
    var showsDivider: Bool = true

    private var override: URL? { settings.soundPack.url(for: event) }

    var body: some View {
        SettingsRow(title: event.label,
                    subtitle: sourceLabel,
                    showsDivider: showsDivider) {
            HStack(spacing: 8) {
                Button(action: preview) {
                    Image(systemName: "play.circle.fill").foregroundStyle(.green)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Preview")

                Button(override == nil ? "Import…" : "Replace…", action: importFile)

                if override != nil {
                    Button("Clear") { settings.setCustomSound(nil, for: event) }
                }
            }
        }
    }

    private var sourceLabel: String {
        guard let url = override else { return "Built-in chiptune cue." }
        let missing = !FileManager.default.fileExists(atPath: url.path)
        return missing ? "Missing: \(url.lastPathComponent) — using built-in cue."
                       : "Custom: \(url.lastPathComponent)"
    }

    private func preview() {
        let wasEnabled = SoundPlayer.shared.enabled
        SoundPlayer.shared.enabled = true          // always audible for preview
        SoundPlayer.shared.play(event)
        SoundPlayer.shared.enabled = wasEnabled
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wav, .aiff, .mp3, .audio]
        panel.prompt = "Choose"
        panel.message = "Choose an audio file for the \(event.label) cue."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setCustomSound(url, for: event)
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

            SettingsGroup(title: "Updates",
                          footnote: "The Beta channel offers pre-release builds before they're promoted to stable.") {
                SettingsRow(title: "Check for Updates…") {
                    Button("Check Now") { Updater.shared.checkForUpdates(userInitiated: true) }
                }
                SettingsRow(title: "Update Channel",
                            subtitle: "Follow stable releases only, or opt into betas.") {
                    // Bind straight to the model (like the toggle below) so the picker
                    // always reflects the persisted channel with no flicker or write-back
                    // loop. Reading `Updater.shared` here is fine — a View body is
                    // main-actor isolated, unlike a stored-property default initializer.
                    Picker("", selection: Binding(
                        get: { Updater.shared.channel },
                        set: { Updater.shared.channel = $0 })) {
                        ForEach(UpdateChannel.allCases) { ch in
                            Text(ch.title).tag(ch)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
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

            SettingsGroup(title: "Feedback",
                          footnote: "Export Diagnostics saves a plain-text report (app and macOS versions, integration health, and recent log lines). It contains metadata only — no session or chat content.") {
                SettingsRow(title: "Report a Problem",
                            subtitle: "Compose a bug report with diagnostics attached.") {
                    Button("Report…") { reportingProblem = true }
                }
                SettingsRow(title: "Export Diagnostics…",
                            subtitle: "Save a support report to share when something isn't working.") {
                    Button("Export…", action: exportDiagnostics)
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

    /// Gather the diagnostics report and let the user save it via a save panel.
    private func exportDiagnostics() {
        let report = DiagnosticsReport.build()
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = DiagnosticsReport.defaultFileName()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
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
