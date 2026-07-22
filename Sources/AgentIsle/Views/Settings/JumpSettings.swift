import SwiftUI

/// Customize how "Jump" focuses a session. Power users add rules that override the
/// built-in terminal/editor detection — either activating a specific app or opening a
/// custom URL scheme with the session's working directory substituted. When no rule
/// matches, the built-in behavior is used unchanged.
struct JumpSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsScaffold(section: .jump) {
            SettingsGroup(title: "Rules",
                          footnote: "Rules are checked in order; the first enabled rule that matches a session — and can act — wins. Match on the terminal name (e.g. Ghostty) or its bundle id. \"Activate app\" brings an app forward by bundle id; \"Open URL\" opens a scheme with {path} replaced by the session's working directory (e.g. x-myeditor://open?path={path}). If nothing matches, Agent Isle uses its built-in behavior.") {
                if settings.jumpRules.isEmpty {
                    HStack {
                        Text("No custom rules yet.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(Array(settings.jumpRules.enumerated()), id: \.element.id) { idx, _ in
                        JumpRuleRow(rule: $settings.jumpRules[idx],
                                    showsDivider: idx < settings.jumpRules.count - 1,
                                    onDelete: { delete(id: settings.jumpRules[idx].id) })
                    }
                }
            }

            HStack {
                Button {
                    settings.jumpRules.append(
                        JumpRule(field: .terminalName, matchValue: "",
                                 strategy: .activateBundle, strategyValue: ""))
                } label: {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                }
                Spacer()
            }

            SettingsGroup(title: "Terminal Title Caveat",
                          footnote: "Precise jumps rely on the CLI leaving the terminal's window/tab title alone so Agent Isle can find the right one. Some agents (Claude Code) rewrite the native title, which can throw off jump targeting in terminals like Warp and Ghostty.") {
                SettingsRow(title: "Claude Code native title",
                            subtitle: "If jumps land on the wrong tab in Warp/Ghostty, disable Claude Code's own terminal-title setting (its CLI setting) so Agent Isle's targeting stays accurate.",
                            showsDivider: false) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .help("This is a CLI-side setting; Agent Isle does not change it for you.")
                }
            }
        }
    }

    private func delete(id: UUID) {
        settings.jumpRules.removeAll { $0.id == id }
    }
}

/// One editable jump rule: match field + value, strategy + value, enable toggle, delete.
private struct JumpRuleRow: View {
    @Binding var rule: JumpRule
    var showsDivider: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Match: field picker + value.
                HStack(spacing: 10) {
                    Text("When")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $rule.field) {
                        ForEach(JumpMatchField.allCases) { field in
                            Text(field.label).tag(field)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 140)

                    Text("is")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    TextField(rule.field.placeholder, text: $rule.matchValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Toggle("", isOn: $rule.enabled)
                        .labelsHidden().toggleStyle(.switch)
                        .help("Enable this rule")

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete rule")
                }

                // Strategy: kind picker + value.
                HStack(spacing: 10) {
                    Text("Then")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $rule.strategy) {
                        ForEach(JumpStrategyKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 140)

                    TextField(rule.strategy.placeholder, text: $rule.strategyValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                Text(rule.strategy.valueHint)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if showsDivider { Divider().padding(.leading, 14) }
        }
    }
}
