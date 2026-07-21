import Foundation

/// Installs / removes the Cursor CLI agent hooks that let you approve tool calls and
/// follow Cursor sessions from the notch in real time. Mirrors `HookInstaller` (Claude
/// Code) but targets `~/.cursor/hooks.json`, whose shape differs: a top-level `version`
/// plus a `hooks` map of event-name → array of `{ "command", "timeout"? }`.
///
/// It copies the bundled bridge script to `~/.agent-isle/` and edits `hooks.json` in
/// place, preserving every hook it doesn't own (so a coexisting tool's hooks survive).
enum CursorHookInstaller {
    /// Events we manage. The `before*` gating hooks block while you decide from the notch,
    /// so they carry a long timeout; the rest are fire-and-forget activity/among/done.
    private static let managedEvents: [(event: String, timeout: Int?)] = [
        ("beforeShellExecution", 300),   // blocks: approve a command from the notch
        ("beforeMCPExecution", 300),     // blocks: approve an MCP tool call
        ("beforeFileEdit", 300),         // blocks: approve a file edit
        ("beforeSubmitPrompt", nil),     // reports the user's prompt
        ("afterShellExecution", nil),
        ("afterMCPExecution", nil),
        ("afterFileEdit", nil),
        ("afterAgentResponse", nil),
        ("stop", nil),                   // marks the session done
    ]
    private static let marker = "agent-isle-cursor-hook"

    private static var fm: FileManager { .default }
    private static var cursorDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }
    private static var hooksURL: URL { cursorDir.appendingPathComponent("hooks.json") }
    private static var installDir: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent(".agent-isle")
    }
    private static var installedHookURL: URL {
        installDir.appendingPathComponent("agent-isle-cursor-hook.py")
    }

    // MARK: - State

    /// True if the user has Cursor (a `~/.cursor` config dir).
    static func hasCursor() -> Bool {
        fm.fileExists(atPath: cursorDir.path)
    }

    /// True only if our hooks are installed AND point at the script that currently exists
    /// on disk — a stale command referencing a deleted script counts as NOT installed, so
    /// we re-prompt and `install()` repairs it (matching `HookInstaller`).
    static func isInstalled() -> Bool {
        guard fm.fileExists(atPath: installedHookURL.path) else { return false }
        guard let hooks = readHooks()?["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            for entry in (value as? [[String: Any]] ?? []) {
                if (entry["command"] as? String)?.contains(installedHookURL.path) == true { return true }
            }
        }
        return false
    }

    // MARK: - Install / uninstall

    @discardableResult
    static func install() -> Bool {
        guard let bundled = bundledHookURL() else {
            NSLog("CursorHookInstaller: bundled hook script not found")
            return false
        }
        do {
            try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedHookURL.path) {
                try? fm.removeItem(at: installedHookURL)
            }
            try fm.copyItem(at: bundled, to: installedHookURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHookURL.path)

            var config = readHooks() ?? [:]
            config["version"] = config["version"] ?? 1
            var hooks = config["hooks"] as? [String: Any] ?? [:]
            let python = resolvePython()

            for spec in managedEvents {
                // Keep foreign hooks for this event; drop only a prior copy of ours.
                var entries = (hooks[spec.event] as? [[String: Any]] ?? []).filter {
                    ($0["command"] as? String)?.contains(marker) != true
                }
                var cmd: [String: Any] = ["command": "\(python) '\(installedHookURL.path)'"]
                if let t = spec.timeout { cmd["timeout"] = t }
                entries.append(cmd)
                hooks[spec.event] = entries
            }
            config["hooks"] = hooks
            return writeHooks(config)
        } catch {
            NSLog("CursorHookInstaller.install failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func uninstall() -> Bool {
        guard var config = readHooks(), var hooks = config["hooks"] as? [String: Any] else {
            return true
        }
        for event in Array(hooks.keys) {
            let kept = (hooks[event] as? [[String: Any]] ?? []).filter {
                ($0["command"] as? String)?.contains(marker) != true
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        return writeHooks(config)
    }

    // MARK: - Helpers

    private static func bundledHookURL() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("agent-isle-cursor-hook.py")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for candidate in [exeDir.appendingPathComponent("agent-isle-cursor-hook.py"),
                          exeDir.appendingPathComponent("../../Scripts/agent-isle-cursor-hook.py")] {
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

    private static func readHooks() -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeHooks(_ config: [String: Any]) -> Bool {
        do {
            try fm.createDirectory(at: cursorDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: hooksURL, options: .atomic)
            return true
        } catch {
            NSLog("CursorHookInstaller.writeHooks failed: \(error)")
            return false
        }
    }
}
