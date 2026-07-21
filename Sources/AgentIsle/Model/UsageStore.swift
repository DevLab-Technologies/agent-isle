import SwiftUI

/// How the Usage view buckets records for its chart and table.
enum UsageGrouping: String, CaseIterable, Identifiable {
    case day, month, project, session
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "By day"
        case .month: return "By month"
        case .project: return "By project"
        case .session: return "By session"
        }
    }
}

/// Time window applied before grouping.
enum UsageRange: String, CaseIterable, Identifiable {
    case week, month, quarter, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .all: return "All time"
        }
    }
    /// Number of days back, or nil for all-time.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }
}

/// One bar/row in the usage chart.
struct UsageBar: Identifiable {
    let id: String
    let label: String        // axis label (unique per bar — used as the chart's category)
    let sortKey: Double       // for stable ordering (date interval or -tokens)
    let tokens: Int
    let detail: String?       // secondary line (e.g. session id for a session)
    var date: Date? = nil     // set for time-series bars so the chart uses a real date axis
}

/// Loads and caches historical usage, exposes filtered aggregates for the Usage view.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var records: [UsageAnalytics.Record] = []
    @Published private(set) var loading = false

    @Published var range: UsageRange = .month
    @Published var grouping: UsageGrouping = .day

    /// Per-file cache keyed by path, invalidated when the file's mtime changes.
    private var cache: [String: (mtime: Date, records: [UsageAnalytics.Record])] = [:]
    private let projectsDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        self.projectsDir = base.appendingPathComponent("projects")
    }

    /// Test seam: seed records directly, bypassing the disk scan.
    convenience init(records: [UsageAnalytics.Record]) {
        self.init()
        self.records = records
    }

    /// Background queue for the (blocking) transcript reads, kept off both the main actor
    /// and the Swift concurrency cooperative pool.
    private static let scanQueue = DispatchQueue(label: "com.devlab.agentisle.usage-scan", qos: .utility)

    /// Re-scan transcripts, reusing cached results for unchanged files. Changed/new files
    /// are parsed concurrently on a background queue. Re-entrant calls (e.g. the section's
    /// `.task` and the sidebar tap firing together) are coalesced by the `loading` guard.
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let files = UsageAnalytics.transcripts(in: projectsDir)

        // Split into cached vs. needs-scan.
        var merged: [UsageAnalytics.Record] = []
        var newCache: [String: (mtime: Date, records: [UsageAnalytics.Record])] = [:]
        var toScan: [(url: URL, mtime: Date, folder: String)] = []
        for f in files {
            let key = f.url.path
            if let c = cache[key], c.mtime == f.mtime {
                newCache[key] = c
                merged += c.records
            } else {
                toScan.append((f.url, f.mtime, f.url.deletingLastPathComponent().lastPathComponent))
            }
        }

        if !toScan.isEmpty {
            // `concurrentPerform` bounds parallelism to the core count and does the blocking
            // file reads off the cooperative pool, so a large project set can't starve it.
            // Capture an immutable snapshot and collect through a Sendable, lock-guarded sink
            // so nothing mutable is captured in the concurrent closure.
            let items = toScan
            let scanned: [(String, Date, [UsageAnalytics.Record])] = await withCheckedContinuation { cont in
                Self.scanQueue.async {
                    let sink = ScanSink()
                    DispatchQueue.concurrentPerform(iterations: items.count) { i in
                        let item = items[i]
                        let recs = UsageAnalytics.scanFile(item.url, folderName: item.folder)
                        sink.add((item.url.path, item.mtime, recs))
                    }
                    cont.resume(returning: sink.drain())
                }
            }
            for (path, mtime, recs) in scanned {
                newCache[path] = (mtime, recs)
                merged += recs
            }
        }

        cache = newCache
        records = merged
    }

    // MARK: - Derived

    /// Records within the selected time range.
    var filtered: [UsageAnalytics.Record] {
        guard let days = range.days else { return records }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: Date()))
            ?? .distantPast
        return records.filter { $0.day >= cutoff }
    }

    var totalTokens: Int { filtered.reduce(0) { $0 + $1.tokens } }
    var sessionCount: Int { Set(filtered.map(\.sessionID)).count }
    var projectCount: Int { Set(filtered.map(\.project)).count }
    var isEmpty: Bool { filtered.isEmpty }

    /// The bars/rows to plot for the current grouping, ordered for display.
    var bars: [UsageBar] {
        switch grouping {
        case .day:     return dayBars(byMonth: false)
        case .month:   return dayBars(byMonth: true)
        case .project: return keyedBars(key: { $0.project }, detail: nil)
        case .session: return sessionBars()
        }
    }

    private func dayBars(byMonth: Bool) -> [UsageBar] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = byMonth ? "MMM yyyy" : "MMM d, yyyy"
        var buckets: [Date: Int] = [:]
        for r in filtered {
            let key = byMonth ? (cal.dateInterval(of: .month, for: r.day)?.start ?? r.day) : r.day
            buckets[key, default: 0] += r.tokens
        }
        return buckets
            .sorted { $0.key < $1.key }
            // id keyed on the real interval so it's unique across years without a formatter;
            // the chart plots by `date` (below), so multi-year day collisions can't occur.
            .map { UsageBar(id: "\(Int($0.key.timeIntervalSince1970))",
                            label: fmt.string(from: $0.key),
                            sortKey: $0.key.timeIntervalSince1970,
                            tokens: $0.value, detail: nil, date: $0.key) }
    }

    private func keyedBars(key: (UsageAnalytics.Record) -> String, detail: String?) -> [UsageBar] {
        var buckets: [String: Int] = [:]
        for r in filtered { buckets[key(r), default: 0] += r.tokens }
        return buckets
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { UsageBar(id: $0.key, label: $0.key, sortKey: -Double($0.value),
                            tokens: $0.value, detail: detail) }
    }

    private func sessionBars() -> [UsageBar] {
        var tokens: [String: Int] = [:]
        var project: [String: String] = [:]
        for r in filtered {
            tokens[r.sessionID, default: 0] += r.tokens
            project[r.sessionID] = r.project
        }
        return tokens
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { entry in
                let short = String(entry.key.prefix(8))
                // Label must be unique per bar — two sessions in the same project would
                // otherwise collapse onto one row. Combine project + short id.
                let proj = project[entry.key] ?? "session"
                return UsageBar(id: entry.key, label: "\(proj) · \(short)",
                                sortKey: -Double(entry.value), tokens: entry.value,
                                detail: nil)
            }
    }
}

/// Lock-guarded collector for parallel scan results. Reference type + `@unchecked
/// Sendable` so it can be captured (as a `let`) and mutated safely inside a
/// `concurrentPerform` closure without tripping strict-concurrency capture rules.
private final class ScanSink: @unchecked Sendable {
    private var out: [(String, Date, [UsageAnalytics.Record])] = []
    private let lock = NSLock()
    func add(_ entry: (String, Date, [UsageAnalytics.Record])) {
        lock.lock(); out.append(entry); lock.unlock()
    }
    func drain() -> [(String, Date, [UsageAnalytics.Record])] {
        lock.lock(); defer { lock.unlock() }; return out
    }
}

/// Compact human-readable token count, e.g. "48.2k" or "1.3M". Shared with the island.
func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
    return "\(tokens)"
}
