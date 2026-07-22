import Foundation

/// Which piece of a session a jump rule matches against.
enum JumpMatchField: String, Codable, CaseIterable, Identifiable {
    case terminalName      // the reported host app name, e.g. "Ghostty"
    case terminalBundleID  // the host app bundle id, e.g. "com.mitchellh.ghostty"

    var id: String { rawValue }

    /// Human label for the settings picker.
    var label: String {
        switch self {
        case .terminalName:     return "Terminal name"
        case .terminalBundleID: return "Bundle id"
        }
    }

    /// Placeholder shown in the match-value field.
    var placeholder: String {
        switch self {
        case .terminalName:     return "Ghostty"
        case .terminalBundleID: return "com.mitchellh.ghostty"
        }
    }
}

/// How a matched jump rule focuses the session.
enum JumpStrategyKind: String, Codable, CaseIterable, Identifiable {
    case activateBundle  // bring an app to the front by bundle id
    case openURL         // open a custom URL scheme, with {path} substituted

    var id: String { rawValue }

    /// Human label for the strategy picker.
    var label: String {
        switch self {
        case .activateBundle: return "Activate app"
        case .openURL:        return "Open URL"
        }
    }

    /// Placeholder shown in the strategy-value field.
    var placeholder: String {
        switch self {
        case .activateBundle: return "com.mitchellh.ghostty"
        case .openURL:        return "x-myeditor://open?path={path}"
        }
    }

    /// Short hint describing what the value field expects.
    var valueHint: String {
        switch self {
        case .activateBundle: return "Bundle id of the app to bring forward."
        case .openURL:        return "URL scheme to open. {path} is replaced with the session's working directory."
        }
    }
}

/// A user-defined rule overriding how "Jump" focuses a session. Rules are evaluated in
/// order; the first enabled rule that matches — and can act — wins, otherwise `Jumper`
/// falls back to its built-in behavior. Persisted as JSON in `UserDefaults`, mirroring
/// the `SessionFilter` pattern.
struct JumpRule: Codable, Identifiable, Equatable {
    var id: UUID
    var field: JumpMatchField
    var matchValue: String
    var strategy: JumpStrategyKind
    var strategyValue: String
    var enabled: Bool

    init(id: UUID = UUID(),
         field: JumpMatchField,
         matchValue: String,
         strategy: JumpStrategyKind,
         strategyValue: String,
         enabled: Bool = true) {
        self.id = id
        self.field = field
        self.matchValue = matchValue
        self.strategy = strategy
        self.strategyValue = strategyValue
        self.enabled = enabled
    }

    /// True when this enabled rule's match value applies to `session`. Matching is an
    /// exact, case-insensitive comparison (bundle ids and terminal names are identifiers).
    func matches(_ session: AgentSession) -> Bool {
        guard enabled else { return false }
        let needle = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        switch field {
        case .terminalName:
            return session.terminal.caseInsensitiveCompare(needle) == .orderedSame
        case .terminalBundleID:
            guard let bundle = session.terminalBundleID else { return false }
            return bundle.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    /// The bundle id to activate for an `.activateBundle` rule (trimmed, non-empty), else nil.
    var activationBundleID: String? {
        guard strategy == .activateBundle else { return nil }
        let value = strategyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The URL to open for an `.openURL` rule, with `{path}` substituted from
    /// `workspacePath`. Returns nil when the template is empty, the resulting string
    /// isn't a valid URL, or the template needs a path the session doesn't have.
    func resolvedURL(workspacePath: String?) -> URL? {
        guard strategy == .openURL else { return nil }
        guard let string = JumpRule.substitute(template: strategyValue, path: workspacePath) else {
            return nil
        }
        return URL(string: string)
    }

    /// Substitute the `{path}` token in `template` with a percent-encoded `path`. Returns
    /// the template unchanged when it has no token; nil when the template is empty, or when
    /// it needs a path but none is available. Pure logic — the unit of behavior under test.
    static func substitute(template: String, path: String?) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains("{path}") else { return trimmed }
        guard let path, !path.isEmpty else { return nil }
        // Keep path separators intact (`.urlPathAllowed` retains `/`) while escaping spaces
        // and other characters unsafe in a URL. Works for both `.../file{path}` and
        // `...?path={path}` shapes.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return trimmed.replacingOccurrences(of: "{path}", with: encoded)
    }

    // MARK: - Persistence (shared by AppSettings and Jumper)

    /// Decode the persisted rule list from `defaults`. Both the settings UI and the
    /// actor-free `Jumper` read through here so there is a single stored representation.
    static func load(from defaults: UserDefaults) -> [JumpRule] {
        guard let data = defaults.data(forKey: DefaultsKeys.jumpRules),
              let rules = try? JSONDecoder().decode([JumpRule].self, from: data) else {
            return []
        }
        return rules
    }

    /// Persist `rules` into `defaults` as JSON.
    static func save(_ rules: [JumpRule], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: DefaultsKeys.jumpRules)
        }
    }

    /// The first enabled rule that matches `session`, read from `defaults`. Nonisolated so
    /// `Jumper` can consult user rules without hopping to the main actor.
    static func firstMatch(for session: AgentSession, in defaults: UserDefaults) -> JumpRule? {
        load(from: defaults).first { $0.matches(session) }
    }
}
