import AppKit

/// Best-effort "jump to the session" — brings the session's terminal or IDE to the
/// front, opening the workspace folder in editors so the right window is focused.
///
/// Precise tab/split targeting (like the original) needs per-terminal scripting; this
/// focuses the app and, for editors, the specific workspace.
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

    static func jump(to session: AgentSession) {
        // Prefer the exact host app the hook reported via TERM_PROGRAM.
        let bundle = session.terminalBundleID ?? bundleIDs[session.terminal]

        // For editors, reopen the workspace so the right window comes forward — this
        // also focuses a session running in the editor's integrated terminal.
        let isEditor = editors.contains(session.terminal)
            || (bundle.map(editorBundles.contains) ?? false)
        if isEditor, let path = session.workspacePath {
            let app = bundle ?? "com.microsoft.VSCode"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", app, path]
            try? proc.run()
            return
        }

        if let bundle {
            activate(bundleID: bundle)
        }
    }

    private static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
