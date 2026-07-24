import SwiftUI

/// Voice-callout settings: an on-device default plus opt-in "bring your own key" cloud voice
/// and AI-written summaries. Mirrors the Sound section's visual language.
struct VoiceSettings: View {
    @EnvironmentObject var settings: AppSettings

    /// The curated natural on-device voices. Enumerated once per launch (statics are lazy) so
    /// re-rendering the pickers doesn't re-scan the installed voices.
    private static let systemVoiceOptions = SystemVoiceCatalog.options()
    /// Agents worth offering a dedicated voice for (everything but the catch-all "unknown").
    private let agents = AgentKind.allCases.filter { $0 != .unknown }

    // Which key fields are relevant to the currently selected providers.
    private var needsOpenAIKey: Bool {
        settings.voiceProvider == .openAI || settings.voiceSummaryProvider == .openAI
    }
    private var needsElevenLabsKey: Bool { settings.voiceProvider == .elevenLabs }
    private var needsAnthropicKey: Bool { settings.voiceSummaryProvider == .anthropic }
    private var anyCloud: Bool { needsOpenAIKey || needsElevenLabsKey || needsAnthropicKey }

    /// True for engines with a known, selectable list of voices (a picker fits). ElevenLabs
    /// voices are account-specific, so it keeps a free-text id field instead.
    private var offersVoicePicker: Bool {
        settings.voiceProvider == .system || settings.voiceProvider == .openAI
    }

    /// The selectable voices ("characters") for the current engine.
    private var engineVoiceOptions: [SystemVoiceOption] {
        switch settings.voiceProvider {
        case .system:     return Self.systemVoiceOptions
        case .openAI:     return SpeechClient.openAIVoices.map { SystemVoiceOption(id: $0, label: $0.capitalized) }
        case .elevenLabs: return SpeechClient.elevenLabsPresets.map { SystemVoiceOption(id: $0.id, label: $0.name) }
        }
    }

    /// The store binding for the current engine's default voice.
    private var defaultVoiceBinding: Binding<String> {
        settings.voiceProvider == .system ? $settings.voiceDefaultVoiceId : $settings.voiceCloudVoice
    }

    /// The store binding for one agent's explicit voice under the current engine ("" = Default).
    private func agentVoiceBinding(_ agent: AgentKind) -> Binding<String> {
        Binding(
            get: {
                settings.voiceProvider == .system
                    ? (settings.voicePerAgent[agent.rawValue] ?? "")
                    : (settings.voiceCloudPerAgent[VoiceConfig.cloudKey(settings.voiceProvider, agent)] ?? "")
            },
            set: { value in
                let voice = value.isEmpty ? nil : value
                if settings.voiceProvider == .system {
                    settings.setVoice(voice, for: agent)
                } else {
                    settings.setCloudVoice(voice, for: agent, provider: settings.voiceProvider)
                }
            })
    }

    var body: some View {
        SettingsScaffold(section: .voice) {
            output
            whenToSpeak
            voiceGroup
            if offersVoicePicker { perAgentGroup }
            summaryGroup
            if anyCloud { keysGroup }
        }
    }

    // MARK: Output

    private var output: some View {
        SettingsGroup(title: "Output") {
            SettingsRow(title: "Enable Voice Callouts",
                        subtitle: "Speak a short line when an agent finishes or needs you.") {
                Toggle("", isOn: $settings.voiceEnabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Volume") {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $settings.voiceVolume, in: 0...1).frame(width: 200)
                        .disabled(!settings.voiceEnabled)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(Int(settings.voiceVolume * 100))%")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            SettingsRow(title: "Preview",
                        subtitle: "Hear a sample completion callout with your current settings.",
                        showsDivider: false) {
                Button("Play") { VoiceAnnouncer.shared.preview() }
            }
        }
    }

    // MARK: When to speak

    private var whenToSpeak: some View {
        SettingsGroup(title: "When To Speak") {
            SettingsRow(title: "On Completion",
                        subtitle: "When an agent finishes its turn.") {
                Toggle("", isOn: $settings.voiceAnnounceOnDone).labelsHidden().toggleStyle(.switch)
                    .disabled(!settings.voiceEnabled)
            }
            SettingsRow(title: "On Attention",
                        subtitle: "When an agent needs a permission, question, or plan decision.",
                        showsDivider: false) {
                Toggle("", isOn: $settings.voiceAnnounceOnAttention).labelsHidden().toggleStyle(.switch)
                    .disabled(!settings.voiceEnabled)
            }
        }
    }

    // MARK: Voice

    private var voiceGroup: some View {
        SettingsGroup(title: "Voice",
                      footnote: "System voice is fully on-device — nothing leaves your Mac. For a far more natural voice, download an Enhanced or Premium one in System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice ▸ Manage Voices. OpenAI and ElevenLabs speak using your own API key and bill you directly.") {
            SettingsRow(title: "Engine") {
                Picker("", selection: $settings.voiceProvider) {
                    ForEach(VoiceProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 200)
            }
            SettingsRow(title: "Style") {
                Picker("", selection: $settings.voiceStyle) {
                    ForEach(VoiceStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 200)
            }
            if offersVoicePicker {
                SettingsRow(title: "Default Voice",
                            subtitle: settings.voiceDistinctPerAgent
                                ? "Used only when Distinct Voice Per Agent is off, or as the fallback."
                                : "Spoken for every agent that has no voice set below.") {
                    Picker("", selection: defaultVoiceBinding) {
                        Text("Automatic (best available)").tag("")
                        ForEach(engineVoiceOptions) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 220)
                    .disabled(settings.voiceDistinctPerAgent)
                }
            }
            SettingsRow(title: "Distinct Voice Per Agent",
                        subtitle: "Auto-assign a different voice to each agent that isn't set below.",
                        showsDivider: settings.voiceProvider == .elevenLabs) {
                Toggle("", isOn: $settings.voiceDistinctPerAgent).labelsHidden().toggleStyle(.switch)
            }
            if settings.voiceProvider == .elevenLabs {
                SettingsRow(title: "Voice",
                            subtitle: cloudVoiceHint,
                            showsDivider: false) {
                    TextField(cloudVoicePlaceholder, text: $settings.voiceCloudVoice)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        }
    }

    // MARK: Per-agent voices

    private var perAgentGroup: some View {
        SettingsGroup(title: "Per-Agent Voices",
                      footnote: "Give any agent its own voice. Leave one on Default to follow the settings above. Tap play to preview.") {
            ForEach(Array(agents.enumerated()), id: \.element) { idx, agent in
                SettingsRow(title: agent.displayName,
                            showsDivider: idx < agents.count - 1) {
                    HStack(spacing: 8) {
                        Button { VoiceAnnouncer.shared.preview(agent: agent) } label: {
                            Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .help("Preview \(agent.displayName)")

                        Picker("", selection: agentVoiceBinding(agent)) {
                            Text("Default").tag("")
                            ForEach(engineVoiceOptions) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 220)
                    }
                }
            }
        }
    }

    private var cloudVoiceHint: String {
        "ElevenLabs voice id. Leave blank to use a premade voice — varied per agent when Distinct is on."
    }
    private var cloudVoicePlaceholder: String { "voice id" }

    // MARK: Summary

    private var summaryGroup: some View {
        SettingsGroup(title: "Summary",
                      footnote: "Built-in phrasing is composed on-device. A provider writes a tighter, more natural line using your own API key.") {
            SettingsRow(title: "Written By", showsDivider: false) {
                Picker("", selection: $settings.voiceSummaryProvider) {
                    ForEach(SummaryProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 200)
            }
        }
    }

    // MARK: Keys

    private var keysGroup: some View {
        SettingsGroup(title: "API Keys",
                      footnote: "Stored in your macOS Keychain, never in plain files or diagnostic exports. Used only for the providers you select above.") {
            if needsOpenAIKey {
                APIKeyField(title: "OpenAI", stored: $settings.openAIKey,
                            showsDivider: needsElevenLabsKey || needsAnthropicKey)
            }
            if needsElevenLabsKey {
                APIKeyField(title: "ElevenLabs", stored: $settings.elevenLabsKey,
                            showsDivider: needsAnthropicKey)
            }
            if needsAnthropicKey {
                APIKeyField(title: "Anthropic", stored: $settings.anthropicKey, showsDivider: false)
            }
        }
    }
}

/// A secure API-key row bound live to the (Keychain-backed) setting, so a just-typed key is
/// immediately visible to previews and callouts. The Keychain write itself is debounced in
/// `AppSettings` and flushed on close/quit, so binding live costs no per-keystroke disk I/O.
private struct APIKeyField: View {
    let title: String
    @Binding var stored: String
    var showsDivider: Bool

    var body: some View {
        SettingsRow(title: title,
                    subtitle: stored.isEmpty ? "Not set" : "Saved to Keychain",
                    showsDivider: showsDivider) {
            SecureField("sk-…", text: $stored)
                .textFieldStyle(.roundedBorder).frame(width: 220)
        }
    }
}
