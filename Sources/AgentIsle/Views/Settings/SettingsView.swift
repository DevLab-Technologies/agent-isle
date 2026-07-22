import SwiftUI

/// The sections shown in the settings sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, integrations, display, filters, sound, usage, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .integrations: return "Integrations"
        case .display: return "Display"
        case .filters: return "Filters"
        case .sound: return "Sound"
        case .usage: return "Usage"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        case .display: return "textformat.size"
        case .filters: return "line.3.horizontal.decrease.circle.fill"
        case .sound: return "speaker.wave.2.fill"
        case .usage: return "chart.bar.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .integrations: return .blue
        case .display: return .purple
        case .filters: return .orange
        case .sound: return .green
        case .usage: return .pink
        case .about: return .blue
        }
    }
}

/// Root of the settings window: a sidebar of sections plus the selected section's detail.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: SessionStore
    @ObservedObject private var usage = UsageStore.shared
    @State private var selection: SettingsSection =
        SettingsSection(rawValue: ProcessInfo.processInfo.environment["AGENT_ISLE_SECTION"] ?? "") ?? .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                if section == .about { Spacer() ; sidebarGroupLabel("Agent Isle") }
                sidebarRow(section)
            }
        }
        .padding(10)
        .frame(width: 212)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
    }

    private func sidebarGroupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let selected = selection == section
        return Button {
            selection = section
            if section == .usage { Task { await usage.refresh() } }
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: section.icon, tint: section.tint)
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.primary.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:      GeneralSettings()
        case .integrations: IntegrationsSettings()
        case .display:      DisplaySettings()
        case .filters:      FiltersSettings()
        case .sound:        SoundSettings()
        case .usage:        UsageSettings(usage: usage)
        case .about:        AboutSettings()
        }
    }
}

// MARK: - Shared building blocks

/// A rounded, tinted icon tile like the competitor's sidebar/section marks.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(tint.gradient))
    }
}

/// Section detail scaffold: a header (icon + title) over a scrollable body.
struct SettingsScaffold<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: section.icon, tint: section.tint, size: 26)
                Text(section.title).font(.system(size: 20, weight: .bold))
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) { content }
                    .padding(.horizontal, 24).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A titled group of rows in a rounded card, matching the settings visual language.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footnote: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
            if let footnote {
                Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A single settings row: title (+ optional subtitle) with a trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var showsDivider: Bool = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if showsDivider { Divider().padding(.leading, 14) }
        }
    }
}
