import Foundation

/// A rolling (or calendar) usage window surfaced next to a live agent. Claude Code and
/// Codex bill against rolling 5-hour and 7-day limits; Cursor is a calendar-monthly plan.
enum UsageWindow: String, CaseIterable, Identifiable {
    case fiveHour, sevenDay, month
    var id: String { rawValue }

    /// Compact label for the island readout ("5h", "7d", "mo").
    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .month:    return "mo"
        }
    }

    /// Fuller label for the settings breakdown.
    var longLabel: String {
        switch self {
        case .fiveHour: return "Last 5 hours"
        case .sevenDay: return "Last 7 days"
        case .month:    return "This month"
        }
    }

    /// Rolling length in seconds; nil for `.month`, which is a calendar month.
    var rollingSeconds: TimeInterval? {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 24 * 3600
        case .month:    return nil
        }
    }

    /// The window's start instant relative to `now`.
    func start(now: Date, calendar: Calendar = .current) -> Date {
        if let seconds = rollingSeconds { return now.addingTimeInterval(-seconds) }
        return calendar.dateInterval(of: .month, for: now)?.start ?? now
    }
}

extension AgentKind {
    /// The usage windows worth surfacing for this agent's plan model. Empty for agents
    /// with no known window model (they get no readout).
    var usageWindows: [UsageWindow] {
        switch self {
        case .claude, .codex: return [.fiveHour, .sevenDay]
        case .cursor:         return [.month]
        default:              return []
        }
    }
}

/// Plan quota caps, in tokens, keyed by (agent, window).
///
/// These are intentionally `nil` ("unknown") by default. Anthropic, OpenAI and Cursor
/// express their limits in plan-specific ways (message counts, prompt units, dollar
/// budgets) that don't map to a single public token number, and this app must not invent
/// quotas. When a *verified* cap is known for a plan, add it to `caps` below and the UI
/// automatically switches from a raw rolling total to a used / cap percentage.
enum UsageCaps {
    /// Editable table of known caps. Left empty on purpose — fill in only with figures
    /// from a real, verified source. Key format: "<agent.rawValue>.<window.rawValue>".
    /// Example (do NOT enable without a source): ["claude.fiveHour": 44_000_000].
    static let caps: [String: Int] = [:]

    static func cap(agent: AgentKind, window: UsageWindow) -> Int? {
        caps["\(agent.rawValue).\(window.rawValue)"]
    }
}

/// One window's usage for one agent.
struct WindowStat: Identifiable {
    let window: UsageWindow
    let usedTokens: Int
    let cap: Int?              // nil when no cap is known
    var id: String { window.id }

    /// Fraction of the cap used (0…1+), or nil when no cap is known.
    var fraction: Double? {
        guard let cap, cap > 0 else { return nil }
        return Double(usedTokens) / Double(cap)
    }

    /// "62%" when a cap is known, otherwise a compact token total like "1.2M".
    var display: String {
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        return formatTokens(usedTokens)
    }
}

/// A live rolling-window readout for one agent, plus a compact one-line summary.
struct AgentWindowUsage {
    let agent: AgentKind
    let stats: [WindowStat]

    /// True when at least one window has a known cap (so a percentage is shown).
    var hasKnownCap: Bool { stats.contains { $0.cap != nil } }

    /// Compact readout, e.g. "5h 62% · 7d 41%" (caps known) or "5h 1.2M · 7d 4.8M"
    /// (no cap known — raw rolling totals).
    var compact: String {
        stats.map { "\($0.window.shortLabel) \($0.display)" }.joined(separator: " · ")
    }
}
