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
            chartCard
            if usage.grouping == .project || usage.grouping == .session {
                breakdownTable
            }
        }
        .task { await usage.refresh() }   // refresh whenever the section appears
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
        // Show at most ~8 evenly-spaced x labels so dense day ranges don't overlap.
        let labels = bars.map(\.label)
        let stride = max(1, labels.count / 8)
        let shownLabels = labels.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        return Chart(bars) { bar in
            BarMark(x: .value("Period", bar.label), y: .value("Tokens", bar.tokens))
                .foregroundStyle(LinearGradient(colors: [.pink, .purple],
                                                startPoint: .top, endPoint: .bottom))
                .cornerRadius(3)
        }
        .chartXScale(domain: labels)
        .chartXAxis { AxisMarks(values: shownLabels) { value in
            AxisValueLabel { if let s = value.as(String.self) { Text(s).font(.system(size: 9)) } }
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
