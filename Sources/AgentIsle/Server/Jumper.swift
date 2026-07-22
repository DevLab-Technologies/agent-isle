import AppKit

/// Best-effort "jump to the session" — brings the *specific* session to the front, not
/// just its host app: Claude Desktop sessions deep-link to the exact conversation, and
/// editor sessions focus the window that already has the workspace open (rather than
/// spawning a new one).
///
/// Precise terminal tab/split targeting still needs per-terminal scripting; for plain
/// terminals we activate the app.
enum Jumper {
    /// Bundle identifiers for the apps we can activate directly.
    private static let bundleIDs: [String: String] = [
        "VS Code": "com.microsoft.VSCode",
        "Cursor": "com.todesktop.230313mzl4w4u92",
        "Windsurf": "com.exafunction.windsurf",
        "iTerm": "com.googlecode.iterm2",
        "iTerm2": "com.googlecode.iterm2",
        "Terminal": "com.apple.Terminal",
        "Ghostty": "com.mitchellh.ghostty",
        "Warp": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
        "Kitty": "net.kovidgoyal.kitty",
        "Desktop": "com.anthropic.claudefordesktop",
    ]

    private static let editors: Set<String> = ["VS Code", "Cursor", "Windsurf"]
    private static let editorBundles: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    /// Claude Desktop hosts many Claude Code sessions in one app, so activating the bundle
    /// alone lands on whatever was last focused. It registers `claude://resume?session=<id>`
    /// to open a specific CLI session by its id.
    private static let claudeDesktopBundle = "com.anthropic.claudefordesktop"

    /// Preferred CLI executable inside an editor bundle's `Contents/Resources/app/bin`.
    /// Every VS Code fork also ships a `code` wrapper, tried as a fallback.
    private static let editorCLINames: [String: String] = [
        "com.microsoft.VSCode": "code",
        "com.microsoft.VSCodeInsiders": "code-insiders",
        "com.visualstudio.code.oss": "code-oss",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
    ]

    static func jump(to session: AgentSession) {
        // User rules win: if one matches and can act, honor it and stop.
        if let rule = JumpRule.firstMatch(for: session, in: .standard),
           applyUserRule(rule, to: session) {
            return
        }

        // Prefer the exact host app the hook reported via TERM_PROGRAM.
        let bundle = session.terminalBundleID ?? bundleIDs[session.terminal]

        // Claude Desktop: open the exact conversation instead of the last-focused one.
        if bundle == claudeDesktopBundle || session.terminal == "Desktop",
           openInClaudeDesktop(session) {
            return
        }

        // For editors, focus the window that already has this workspace open — this also
        // focuses a session running in the editor's integrated terminal.
        let isEditor = editors.contains(session.terminal)
            || (bundle.map(editorBundles.contains) ?? false)
        if isEditor, let path = session.workspacePath {
            let app = bundle ?? "com.microsoft.VSCode"
            if openInEditor(bundleID: app, path: path) { return }
            // No usable CLI — fall back to the document-open path.
            openViaOpen(bundleID: app, path: path)
            return
        }

        if let bundle {
            activate(bundleID: bundle)
        }
    }

    /// Deep-link to a specific Claude Code session inside Claude Desktop. Returns false
    /// when we can't build the link, so `jump` can fall back to activating the app.
    private static func openInClaudeDesktop(_ session: AgentSession) -> Bool {
        guard let url = claudeResumeURL(for: session) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// The `claude://resume?session=<cli-session-id>` link that opens this session in
    /// Claude Desktop. The CLI session id is a UUID, taken from the transcript filename
    /// (`~/.claude/projects/<slug>/<uuid>.jsonl`); nil when there's no UUID-named transcript.
    static func claudeResumeURL(for session: AgentSession) -> URL? {
        guard let stem = session.transcriptURL?.deletingPathExtension().lastPathComponent,
              UUID(uuidString: stem) != nil else { return nil }
        return URL(string: "claude://resume?session=\(stem)")
    }

    /// Open/focus `path` with the editor's bundled CLI (`code`, `cursor`, …). The CLI
    /// focuses an existing window that already has the folder open instead of spawning a
    /// new one — which `open -b` does unreliably, landing on a random window. Returns false
    /// when no CLI is found or it can't be launched, so `jump` can fall back to `open`.
    private static func openInEditor(bundleID: String, path: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let binDir = appURL.appendingPathComponent("Contents/Resources/app/bin")
        let fm = FileManager.default
        for name in [editorCLINames[bundleID], "code"].compactMap({ $0 }) {
            let cli = binDir.appendingPathComponent(name)
            guard fm.isExecutableFile(atPath: cli.path) else { continue }
            let proc = Process()
            proc.executableURL = cli
            proc.arguments = [path]
            guard (try? proc.run()) != nil else { continue }
            // The CLI focuses the right window but won't always raise a backgrounded app.
            activate(bundleID: bundleID)
            return true
        }
        return false
    }

    /// Last-resort open: hand the folder to the app via `/usr/bin/open`.
    private static func openViaOpen(bundleID: String, path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-b", bundleID, path]
        try? proc.run()
    }

    /// Apply a matched user rule. Returns false when the rule can't act (empty/invalid
    /// value, or the target app isn't installed), so `jump` falls back to built-in behavior.
    private static func applyUserRule(_ rule: JumpRule, to session: AgentSession) -> Bool {
        switch rule.strategy {
        case .activateBundle:
            guard let bundleID = rule.activationBundleID else { return false }
            return activate(bundleID: bundleID)
        case .openURL:
            guard let url = rule.resolvedURL(workspacePath: session.workspacePath) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    /// Bring the app with `bundleID` forward. Returns false when it isn't installed.
    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }
}
