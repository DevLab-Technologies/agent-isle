import SwiftUI

/// Manage which sessions the island shows: a built-in probe/worker preset plus a list of
/// user-defined hide rules. Hidden sessions are never dropped silently — the island shows a
/// "+N hidden" note that links back here.
struct FiltersSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: SessionStore

    var body: some View {
        SettingsScaffold(section: .filters) {
            SettingsGroup(title: "Presets",
                          footnote: "Hides short-lived internal helper sessions — those whose title looks like a probe or worker, or that run from a temporary directory — so the island stays focused on real work.") {
                SettingsRow(title: "Hide probe / worker sessions",
                            subtitle: "Skip machine-spawned helper sessions.",
                            showsDivider: false) {
                    Toggle("", isOn: $settings.hideProbeWorkers).labelsHidden().toggleStyle(.switch)
                }
            }

            SettingsGroup(title: "Rules",
                          footnote: "A session is hidden when any enabled rule matches it. Working-directory matches on a path prefix, Title matches a substring, and Launcher app matches the exact bundle id.") {
                if settings.sessionFilters.isEmpty {
                    HStack {
                        Text("No rules yet.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ForEach(Array(settings.sessionFilters.enumerated()), id: \.element.id) { idx, _ in
                        FilterRuleRow(rule: $settings.sessionFilters[idx],
                                      showsDivider: idx < settings.sessionFilters.count - 1,
                                      onDelete: { delete(id: settings.sessionFilters[idx].id) })
                    }
                }
            }

            HStack {
                Button {
                    settings.sessionFilters.append(SessionFilter(field: .workspacePath, value: ""))
                } label: {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                }
                Spacer()
                if store.hiddenCount > 0 {
                    Text("\(store.hiddenCount) session\(store.hiddenCount == 1 ? "" : "s") hidden now")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func delete(id: UUID) {
        settings.sessionFilters.removeAll { $0.id == id }
    }
}

/// One editable rule: field picker, value field, enable toggle, and a delete button.
private struct FilterRuleRow: View {
    @Binding var rule: SessionFilter
    var showsDivider: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $rule.field) {
                    ForEach(FilterField.allCases) { field in
                        Text(field.label).tag(field)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150)

                Text(rule.field.matchDescription)
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                TextField(rule.field.placeholder, text: $rule.value)
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
            .padding(.horizontal, 14).padding(.vertical, 10)
            if showsDivider { Divider().padding(.leading, 14) }
        }
    }
}
