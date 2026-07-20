import Foundation

/// Installs / removes the Claude Code hooks that let you approve permissions from the
/// notch. Works from inside the distributed app: it copies the bundled hook script to a
/// stable location (`~/.agent-isle/`) and edits `~/.claude/settings.json` in place,
/// preserving any hooks it doesn't own.
enum HookInstaller {
    private static let managedEvents: [(event: String, kind: String, timeout: Int?)] = [
        ("PreToolUse", "pretooluse", 300),   // blocks while you decide from the notch
        ("PostToolUse", "posttooluse", nil),
        ("Notification", "notification", nil),
        ("Stop", "stop", nil),
        ("UserPromptSubmit", "userprompt", nil),
    ]
    private static let marker = "agent-isle-hook"

    private static var fm: FileManager { .default }
    private static var claudeDir: URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    private static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }
    private static var installDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".agent-isle")
    }
    private static var installedHookURL: URL {
        installDir.appendingPathComponent("agent-isle-hook.py")
    }

    // MARK: - State

    /// True if the user has Claude Code (a `~/.claude` config dir).
    static func hasClaudeCode() -> Bool {
        fm.fileExists(atPath: claudeDir.path)
    }

    /// True only if our hooks are installed AND point at the script that currently
    /// exists on disk. A hook that merely carries the marker but references an old
    /// path (or a script that's been deleted) counts as NOT installed, so we
    /// re-prompt and `install()` repairs it. A stale command like this is also what
    /// can block every Claude Code tool call, so we never treat it as "done".
    static func isInstalled() -> Bool {
        guard fm.fileExists(atPath: installedHookURL.path) else { return false }
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for cmd in (group["hooks"] as? [[String: Any]] ?? []) {
                    if (cmd["command"] as? String)?.contains(installedHookURL.path) == true { return true }
                }
            }
        }
        return false
    }

    // MARK: - Install / uninstall

    @discardableResult
    static func install() -> Bool {
        guard let bundled = bundledHookURL() else {
            NSLog("HookInstaller: bundled hook script not found")
            return false
        }
        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedHookURL.path) {
                try? fm.removeItem(at: installedHookURL)
            }
            try fm.copyItem(at: bundled, to: installedHookURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHookURL.path)

            var settings = readSettings() ?? [:]
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            let python = resolvePython()

            for spec in managedEvents {
                var groups = (hooks[spec.event] as? [[String: Any]] ?? []).filter { group in
                    !((group["hooks"] as? [[String: Any]] ?? []).contains {
                        ($0["command"] as? String)?.contains(marker) == true
                    })
                }
                var cmd: [String: Any] = [
                    "type": "command",
                    "command": "\(python) '\(installedHookURL.path)' \(spec.kind)",
                ]
                if let t = spec.timeout { cmd["timeout"] = t }
                var group: [String: Any] = ["hooks": [cmd]]
                if spec.event == "PreToolUse" || spec.event == "PostToolUse" { group["matcher"] = "*" }
                groups.append(group)
                hooks[spec.event] = groups
            }
            settings["hooks"] = hooks
            return writeSettings(settings)
        } catch {
            NSLog("HookInstaller.install failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var settings = readSettings(), var hooks = settings["hooks"] as? [String: Any] else {
            return true
        }
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                let cmds = (group["hooks"] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(marker) != true
                }
                if cmds.isEmpty { return nil }
                var g = group; g["hooks"] = cmds; return g
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return writeSettings(settings)
    }

    // MARK: - Helpers

    private static func bundledHookURL() -> URL? {
        // In the packaged .app the script sits in Contents/Resources.
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("agent-isle-hook.py")
            if fm.fileExists(atPath: u.path) { return u }
        }
        // Dev fallback: alongside the executable or in a sibling Scripts dir.
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for candidate in [exeDir.appendingPathComponent("agent-isle-hook.py"),
                          exeDir.appendingPathComponent("../../Scripts/agent-isle-hook.py")] {
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func resolvePython() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) } ?? "python3"
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("HookInstaller.writeSettings failed: \(error)")
            return false
        }
    }
}
