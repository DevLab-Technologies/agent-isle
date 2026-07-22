import Foundation

/// Which piece of a session a filter rule matches against.
enum FilterField: String, Codable, CaseIterable, Identifiable {
    case workspacePath   // the session's working directory (cwd)
    case title           // the first-prompt / branch title
    case terminalBundleID // the launcher app's bundle id

    var id: String { rawValue }

    /// Human label for the settings picker.
    var label: String {
        switch self {
        case .workspacePath:   return "Working directory"
        case .title:           return "Title"
        case .terminalBundleID: return "Launcher app"
        }
    }

    /// How the rule's value is compared, described for the UI.
    var matchDescription: String {
        switch self {
        case .workspacePath:    return "starts with"
        case .title:            return "contains"
        case .terminalBundleID: return "is"
        }
    }

    /// Placeholder shown in the value field.
    var placeholder: String {
        switch self {
        case .workspacePath:    return "/Users/me/scratch"
        case .title:            return "wip"
        case .terminalBundleID: return "com.apple.Terminal"
        }
    }
}

/// A user-defined rule that hides sessions matching a field/value pair. Rules are OR-ed:
/// a session is hidden if any enabled rule matches it.
struct SessionFilter: Codable, Identifiable, Equatable {
    var id: UUID
    var field: FilterField
    var value: String
    var enabled: Bool

    init(id: UUID = UUID(), field: FilterField, value: String, enabled: Bool = true) {
        self.id = id
        self.field = field
        self.value = value
        self.enabled = enabled
    }

    /// True when this rule (if enabled and non-empty) hides `session`.
    func matches(_ session: AgentSession) -> Bool {
        guard enabled else { return false }
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        switch field {
        case .workspacePath:
            guard let path = session.workspacePath else { return false }
            return path.hasPrefix(needle)
        case .title:
            return session.title.range(of: needle, options: .caseInsensitive) != nil
        case .terminalBundleID:
            guard let bundle = session.terminalBundleID else { return false }
            return bundle.caseInsensitiveCompare(needle) == .orderedSame
        }
    }
}

/// Built-in heuristic that hides short-lived internal helper sessions ("probes" and
/// "workers") so the island stays focused on real work. Toggled by
/// `AppSettings.hideProbeWorkers`. Kept deliberately conservative — it only hides sessions
/// that look like machine-spawned helpers, never a real coding session.
enum ProbeWorkerHeuristic {
    /// Title keywords that mark a helper/probe session.
    private static let keywords = ["probe", "worker", "healthcheck", "warmup", "keepalive"]
    /// Directory prefixes that only ever hold throwaway/helper work.
    private static let tempPrefixes = ["/tmp/", "/private/tmp/", "/private/var/folders/", "/var/folders/"]

    static func isProbeWorker(_ session: AgentSession) -> Bool {
        let title = session.title.lowercased()
        if keywords.contains(where: { title.contains($0) }) { return true }
        if let path = session.workspacePath,
           tempPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        // An unidentified agent that is idle, untitled, and doing no tracked work reads as
        // an internal helper rather than a session worth surfacing.
        if session.agent == .unknown, session.status == .idle,
           session.tasks.isEmpty, session.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        return false
    }
}
