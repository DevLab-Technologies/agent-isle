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

    static func jump(to session: AgentSession) {
        // Editors: reopen the workspace so its window comes forward.
        if editors.contains(session.terminal), let path = session.workspacePath {
            let app = editorAppName(session.terminal)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", app, path]
            try? proc.run()
            return
        }
        // Otherwise just bring the app to the front.
        if let bundleID = bundleIDs[session.terminal] {
            activate(bundleID: bundleID)
        }
    }

    private static func editorAppName(_ terminal: String) -> String {
        switch terminal {
        case "VS Code": return "Visual Studio Code"
        case "Cursor": return "Cursor"
        case "Windsurf": return "Windsurf"
        default: return terminal
        }
    }

    private static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
