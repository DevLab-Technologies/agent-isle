import SwiftUI
import Charts

/// Usage insights: token totals over time and by project/session, with range + grouping
/// filters. Data comes from `UsageStore`, which scans transcripts and caches by mtime.
struct UsageSettings: View {
    @ObservedObject var usage: UsageStore

    var body: some View {
        SettingsScaffold(section: .usage) {
            filters
            summary
            windowsCard
            chartCard
            if usage.grouping == .project || usage.grouping == .session {
                breakdownTable
            }
        }
        .task { await usage.refresh() }   // refresh whenever the section appears
    }

    // MARK: Rolling windows

    @ViewBuilder private var windowsCard: some View {
        let usages = usage.activeWindowUsages
        if !usages.isEmpty {
            SettingsGroup(title: "Current usage windows",
                          footnote: "Rolling totals for the current period. Percentages appear only where a plan cap is known; otherwise the raw rolling total is shown.") {
                ForEach(Array(usages.enumerated()), id: \.element.agent.id) { agentIdx, agentUsage in
                    ForEach(Array(agentUsage.stats.enumerated()), id: \.element.id) { statIdx, stat in
                        let isLast = agentIdx == usages.count - 1 && statIdx == agentUsage.stats.count - 1
                        SettingsRow(title: "\(agentUsage.agent.displayName) · \(stat.window.longLabel)",
                                    subtitle: stat.cap == nil ? "No plan cap known" : nil,
                                    showsDivider: !isLast) {
                            WindowStatTrailing(stat: stat, tint: agentUsage.agent.tint)
                        }
                    }
                }
            }
        }
    }

    // MARK: Filters

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("", selection: $usage.grouping) {
                ForEach(UsageGrouping.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)

            Spacer(minLength: 8)

            Picker("", selection: $usage.range) {
                ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 130)

            if usage.loading { ProgressView().controlSize(.small) }
        }
    }

    // MARK: Summary tiles

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(value: formatTokens(usage.totalTokens), caption: "Total tokens", tint: .pink)
            StatTile(value: "\(usage.sessionCount)", caption: "Sessions", tint: .blue)
            StatTile(value: "\(usage.projectCount)", caption: "Projects", tint: .purple)
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        SettingsGroup(title: chartTitle) {
            Group {
                if usage.isEmpty {
                    emptyState
                } else if usage.grouping == .day || usage.grouping == .month {
                    timeSeriesChart
                } else {
                    rankingChart
                }
            }
            .padding(14)
        }
    }

    private var chartTitle: String {
        switch usage.grouping {
        case .day: return "Tokens per day"
        case .month: return "Tokens per month"
        case .project: return "Tokens per project"
        case .session: return "Tokens per session"
        }
    }

    private var timeSeriesChart: some View {
        let bars = usage.bars
        let byMonth = usage.grouping == .month
        let unit: Calendar.Component = byMonth ? .month : .day
        // A real date axis lets Charts space and thin labels itself, and keeps days
        // unique across years (no categorical-label collisions).
        return Chart(bars) { bar in
            if let date = bar.date {
                BarMark(x: .value("Period", date, unit: unit), y: .value("Tokens", bar.tokens))
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple],
                                                    startPoint: .top, endPoint: .bottom))
                    .cornerRadius(3)
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) { value in
            AxisValueLabel {
                if let d = value.as(Date.self) {
                    Text(d, format: byMonth ? .dateTime.month(.abbreviated).year()
                                            : .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9))
                }
            }
        } }
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let n = value.as(Int.self) { Text(formatTokens(n)).font(.system(size: 9)) } }
        } }
        .frame(height: 220)
    }

    private var rankingChart: some View {
        let bars = usage.bars
        return Chart(bars) { bar in
            BarMark(x: .value("Tokens", bar.tokens), y: .value("Name", bar.label))
                .foregroundStyle(LinearGradient(colors: [.pink, .orange],
                                                startPoint: .leading, endPoint: .trailing))
                .cornerRadius(3)
        }
        .chartYScale(domain: bars.map(\.label))   // preserve token-desc order
        .chartXAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let n = value.as(Int.self) { Text(formatTokens(n)).font(.system(size: 9)) } }
        } }
        .chartYAxis { AxisMarks { AxisValueLabel().font(.system(size: 9)) } }
        .frame(height: max(160, CGFloat(bars.count) * 26 + 40))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No usage in this range")
                .font(.system(size: 13, weight: .medium))
            Text("Run some Claude Code sessions and they'll show up here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 200)
    }

    // MARK: Breakdown table (project / session)

    private var breakdownTable: some View {
        SettingsGroup(title: usage.grouping == .project ? "Projects" : "Sessions") {
            let bars = usage.bars
            let max = bars.map(\.tokens).max() ?? 1
            ForEach(Array(bars.enumerated()), id: \.element.id) { idx, bar in
                SettingsRow(title: bar.label, subtitle: bar.detail,
                            showsDivider: idx < bars.count - 1) {
                    HStack(spacing: 10) {
                        // Inline proportion bar.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(Color.pink.opacity(0.7))
                                    .frame(width: geo.size.width * CGFloat(bar.tokens) / CGFloat(max))
                            }
                        }
                        .frame(width: 120, height: 5)
                        Text(formatTokens(bar.tokens))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Trailing readout for one rolling window: a used/cap percentage bar when a cap is
/// known, otherwise the raw rolling token total.
private struct WindowStatTrailing: View {
    let stat: WindowStat
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = stat.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint.opacity(0.8))
                            .frame(width: geo.size.width * CGFloat(min(fraction, 1)))
                    }
                }
                .frame(width: 120, height: 5)
                Text(stat.display)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            } else {
                Text(formatTokens(stat.usedTokens))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(alignment: .trailing)
            }
        }
    }
}

/// A compact stat card for the usage summary row.
private struct StatTile: View {
    let value: String
    let caption: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}
