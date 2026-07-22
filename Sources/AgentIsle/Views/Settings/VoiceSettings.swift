import SwiftUI

/// Voice-callout settings: an on-device default plus opt-in "bring your own key" cloud voice
/// and AI-written summaries. Mirrors the Sound section's visual language.
struct VoiceSettings: View {
    @EnvironmentObject var settings: AppSettings

    // Which key fields are relevant to the currently selected providers.
    private var needsOpenAIKey: Bool {
        settings.voiceProvider == .openAI || settings.voiceSummaryProvider == .openAI
    }
    private var needsElevenLabsKey: Bool { settings.voiceProvider == .elevenLabs }
    private var needsAnthropicKey: Bool { settings.voiceSummaryProvider == .anthropic }
    private var anyCloud: Bool { needsOpenAIKey || needsElevenLabsKey || needsAnthropicKey }

    var body: some View {
        SettingsScaffold(section: .voice) {
            output
            whenToSpeak
            voiceGroup
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
                      footnote: "System voice is fully on-device — nothing leaves your Mac. OpenAI and ElevenLabs speak using your own API key and bill you directly.") {
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
            SettingsRow(title: "Distinct Voice Per Agent",
                        subtitle: "Give Claude, Codex, Cursor, and the rest their own voice.",
                        showsDivider: settings.voiceProvider.isCloud) {
                Toggle("", isOn: $settings.voiceDistinctPerAgent).labelsHidden().toggleStyle(.switch)
            }
            if settings.voiceProvider.isCloud {
                SettingsRow(title: "Voice",
                            subtitle: cloudVoiceHint,
                            showsDivider: false) {
                    TextField(cloudVoicePlaceholder, text: $settings.voiceCloudVoice)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        }
    }

    private var cloudVoiceHint: String {
        settings.voiceProvider == .openAI
            ? "OpenAI voice name. Leave blank to auto-pick per agent."
            : "ElevenLabs voice id. Leave blank for the default voice."
    }
    private var cloudVoicePlaceholder: String {
        settings.voiceProvider == .openAI ? "nova" : "voice id"
    }

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

/// A secure API-key row. Edits are held in local state and only written back to the stored
/// (Keychain-backed) binding on commit — pressing Return or leaving the field/section — so we
/// don't perform synchronous Keychain I/O on every keystroke.
private struct APIKeyField: View {
    let title: String
    @Binding var stored: String
    var showsDivider: Bool
    @State private var draft = ""

    var body: some View {
        SettingsRow(title: title,
                    subtitle: stored.isEmpty ? "Not set" : "Saved to Keychain",
                    showsDivider: showsDivider) {
            SecureField("sk-…", text: $draft)
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .onAppear { draft = stored }
                .onSubmit(commit)
                .onDisappear(perform: commit)
        }
    }

    private func commit() {
        if draft != stored { stored = draft }
    }
}
