import Foundation

/// A single, generalized description of a coding-CLI integration: how to detect it, where
/// its config lives, whether Agent Isle can install a notch-approval hook for it, and where
/// its history sits (for the read-only "monitor" agents and the health checks).
///
/// This is the one source of truth the launch flow, the gear menu, the Integrations
/// settings pane, and `IntegrationDoctor` all read from. Adding a new CLI is a matter of
/// appending one `CLIIntegration` to `all` — supply a `GenericHookInstaller` when the CLI
/// exposes a settings file + hook mechanism, or leave it `nil` for a monitor-only agent.
struct CLIIntegration: Identifiable {
    /// What Agent Isle can do with this CLI.
    enum Capability {
        case hook        // installs a notch-approval hook (real-time gating + activity)
        case liveChat    // no hook, but its history is parsed for live chat / activity
        case monitorOnly // detected only; no hook and no history parser yet
    }

    let agent: AgentKind
    /// Directory whose presence means "this CLI is installed" (e.g. `~/.claude`).
    let configDir: URL
    /// The hook installer, or `nil` for an agent with no hook mechanism.
    let hook: GenericHookInstaller?
    /// Directory Agent Isle reads this agent's activity from (for the doctor's readability
    /// check and to explain what "monitor only" means). `nil` when nothing is read.
    let historyDir: URL?

    var id: String { agent.rawValue }
    var displayName: String { agent.displayName }

    /// True when the CLI itself appears installed (its config dir exists).
    func hasCLI() -> Bool {
        FileManager.default.fileExists(atPath: configDir.path)
    }

    var capability: Capability {
        if hook != nil { return .hook }
        return ChatHistory.isSupported(agent) ? .liveChat : .monitorOnly
    }

    /// A short human label for the non-hook agents shown in settings.
    var monitorLabel: String {
        switch capability {
        case .hook: return "Hook"
        case .liveChat: return "Live chat"
        case .monitorOnly: return "Monitor only"
        }
    }

    // MARK: - Registry

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code honors `CLAUDE_CONFIG_DIR`; everything else is a fixed dot-dir in `$HOME`.
    private static var claudeConfigDir: URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }

    static let claude = CLIIntegration(
        agent: .claude,
        configDir: claudeConfigDir,
        hook: GenericHookInstaller(
            format: .claude,
            marker: "agent-isle-hook",
            scriptResource: "agent-isle-hook.py",
            agentName: "claude",
            settingsFileName: "settings.json",
            configDirProvider: { claudeConfigDir },
            events: [
                HookEvent(name: "PreToolUse", scriptArg: "pretooluse", timeout: 300, matcher: "*"),
                HookEvent(name: "PostToolUse", scriptArg: "posttooluse", timeout: nil, matcher: "*"),
                HookEvent(name: "Notification", scriptArg: "notification", timeout: nil, matcher: nil),
                HookEvent(name: "Stop", scriptArg: "stop", timeout: nil, matcher: nil),
                HookEvent(name: "UserPromptSubmit", scriptArg: "userprompt", timeout: nil, matcher: nil),
            ]),
        historyDir: claudeConfigDir.appendingPathComponent("projects"))

    static let cursor = CLIIntegration(
        agent: .cursor,
        configDir: home.appendingPathComponent(".cursor"),
        hook: GenericHookInstaller(
            format: .cursor,
            marker: "agent-isle-cursor-hook",
            scriptResource: "agent-isle-cursor-hook.py",
            agentName: "cursor",
            settingsFileName: "hooks.json",
            configDirProvider: { home.appendingPathComponent(".cursor") },
            events: [
                HookEvent(name: "beforeShellExecution", scriptArg: nil, timeout: 300, matcher: nil),
                HookEvent(name: "beforeMCPExecution", scriptArg: nil, timeout: 300, matcher: nil),
                HookEvent(name: "beforeFileEdit", scriptArg: nil, timeout: 300, matcher: nil),
                HookEvent(name: "beforeSubmitPrompt", scriptArg: nil, timeout: nil, matcher: nil),
                HookEvent(name: "afterShellExecution", scriptArg: nil, timeout: nil, matcher: nil),
                HookEvent(name: "afterMCPExecution", scriptArg: nil, timeout: nil, matcher: nil),
                HookEvent(name: "afterFileEdit", scriptArg: nil, timeout: nil, matcher: nil),
                HookEvent(name: "afterAgentResponse", scriptArg: nil, timeout: nil, matcher: nil),
                HookEvent(name: "stop", scriptArg: nil, timeout: nil, matcher: nil),
            ]),
        historyDir: home.appendingPathComponent(".cursor/chats"))

    // Monitor-only agents. These CLIs do not (currently) expose a shell-command hook
    // mechanism, so Agent Isle reads their history instead of gating their tools. If any
    // of them ships a hook contract later, give it a `GenericHookInstaller` above and it
    // flows through every surface automatically.
    static let grok = CLIIntegration(
        agent: .grok,
        configDir: home.appendingPathComponent(".grok"),
        hook: nil,
        historyDir: home.appendingPathComponent(".grok/sessions"))

    static let copilot = CLIIntegration(
        agent: .copilot,
        configDir: home.appendingPathComponent(".copilot"),
        hook: nil,
        historyDir: home.appendingPathComponent(".copilot/history-session-state"))

    static let gemini = CLIIntegration(
        agent: .gemini,
        configDir: home.appendingPathComponent(".gemini"),
        hook: nil,
        historyDir: nil)

    // Monitor-only agents whose sessions are read from history (no hook mechanism). Each
    // appears in settings only when its config/data location exists (`hasCLI`), so an
    // absent or assumed path simply hides the row rather than showing a wrong status. The
    // paths mirror the scanners in `ExternalAgents`, the single source of truth.

    static let codex = CLIIntegration(
        agent: .codex,
        configDir: home.appendingPathComponent(".codex"),
        hook: nil,
        historyDir: home.appendingPathComponent(".codex/sessions"))

    static let opencode = CLIIntegration(
        agent: .opencode,
        configDir: home.appendingPathComponent(".local/share/opencode"),
        hook: nil,
        historyDir: home.appendingPathComponent(".local/share/opencode/storage/session"))

    static let goose = CLIIntegration(
        agent: .goose,
        configDir: home.appendingPathComponent(".local/share/goose"),
        hook: nil,
        historyDir: home.appendingPathComponent(".local/share/goose/sessions"))

    // Qwen Code's layout is assumed to mirror Gemini CLI's under `~/.qwen` (see
    // ExternalAgents); the presence gate means it only shows if that path exists.
    static let qwen = CLIIntegration(
        agent: .qwen,
        configDir: home.appendingPathComponent(".qwen"),
        hook: nil,
        historyDir: home.appendingPathComponent(".qwen/tmp"))

    // Cline is a VS Code-family extension, not a CLI. This entry detects the VS Code
    // ("Code") host; the extension under other hosts (Cursor, Windsurf) isn't covered by
    // this single path but is still picked up by the session scanner.
    static let cline = CLIIntegration(
        agent: .cline,
        configDir: home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"),
        hook: nil,
        historyDir: home.appendingPathComponent("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"))

    // Aider has no central registry — it writes `.aider.chat.history.md` into whatever
    // directory it runs in, so only the home-dir copy is detectable from a fixed path.
    static let aider = CLIIntegration(
        agent: .aider,
        configDir: home.appendingPathComponent(".aider.chat.history.md"),
        hook: nil,
        historyDir: home.appendingPathComponent(".aider.chat.history.md"))

    /// Every integration Agent Isle knows about, hook-capable first.
    static let all: [CLIIntegration] = [claude, cursor, grok, copilot, gemini,
                                        codex, opencode, goose, qwen, cline, aider]

    /// The subset that can install a hook.
    static var hookCapable: [CLIIntegration] { all.filter { $0.hook != nil } }
}

// MARK: - Hook installer

/// One managed hook event. `scriptArg` is passed to the bridge for CLIs (Claude Code) that
/// disambiguate events by argument; Cursor-style bridges read the event name from stdin and
/// leave it `nil`. `matcher` is Claude Code's per-group tool matcher.
struct HookEvent {
    let name: String
    let scriptArg: String?
    let timeout: Int?
    let matcher: String?
}

/// Generalized hook installer that edits a CLI's JSON settings file in place to register
/// (or remove) Agent Isle's bridge hook, preserving every hook it doesn't own. It supports
/// the two config shapes we've encountered:
///
///  - `.claude`: `hooks` is a map of event → `[{ "matcher"?, "hooks": [{type,command,timeout?}] }]`.
///  - `.cursor`: top-level `version` + `hooks` map of event → `[{command, timeout?}]`.
///
/// Both copy the bundled bridge script to `~/.agent-isle/` and point the hook command at it,
/// so an app move/reinstall repairs cleanly. All operations are idempotent and reversible.
struct GenericHookInstaller {
    enum Format { case claude, cursor }

    let format: Format
    let marker: String
    let scriptResource: String
    let agentName: String
    let settingsFileName: String
    let configDirProvider: () -> URL
    let events: [HookEvent]

    private var fm: FileManager { .default }
    var configDir: URL { configDirProvider() }
    var settingsURL: URL { configDir.appendingPathComponent(settingsFileName) }
    static var installDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-isle")
    }
    var installedScriptURL: URL { Self.installDir.appendingPathComponent(scriptResource) }

    // MARK: State

    /// Installed only if our bridge script exists on disk AND the settings file carries a
    /// hook command that points at that exact script path. A marker that references an old
    /// or deleted path counts as NOT installed, so `install()` repairs it.
    func isInstalled() -> Bool {
        guard fm.fileExists(atPath: installedScriptURL.path) else { return false }
        return settingsReferencesScript()
    }

    /// True when the installed bridge script targets the given `/event` port. Used by the
    /// doctor to catch a stale bridge left over from an older port.
    func scriptTargetsPort(_ port: UInt16) -> Bool {
        guard let text = try? String(contentsOf: installedScriptURL, encoding: .utf8) else { return false }
        return text.contains("localhost:\(port)")
    }

    // MARK: Install / uninstall

    @discardableResult
    func install() -> Bool {
        guard let bundled = bundledScriptURL() else {
            NSLog("GenericHookInstaller[\(agentName)]: bundled script \(scriptResource) not found")
            return false
        }
        do {
            try fm.createDirectory(at: Self.installDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedScriptURL.path) { try? fm.removeItem(at: installedScriptURL) }
            try fm.copyItem(at: bundled, to: installedScriptURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScriptURL.path)

            let settings = readSettings() ?? [:]
            let command = Self.commandBuilder(scriptPath: installedScriptURL.path, agentName: agentName)
            let updated = Self.applyingHook(to: settings, format: format, events: events,
                                            marker: marker, command: command)
            return writeSettings(updated)
        } catch {
            NSLog("GenericHookInstaller[\(agentName)].install failed: \(error)")
            return false
        }
    }

    @discardableResult
    func uninstall() -> Bool {
        guard let settings = readSettings() else { return true }
        return writeSettings(Self.removingHook(from: settings, format: format, marker: marker))
    }

    // MARK: Pure JSON transforms (unit-testable without the app bundle / filesystem)

    /// The shell command for a given event. Claude Code disambiguates events by a positional
    /// argument and tags the agent explicitly; Cursor reads the event from stdin.
    static func commandBuilder(scriptPath: String, agentName: String) -> (HookEvent, Format) -> String {
        let python = resolvePython()
        return { event, format in
            switch format {
            case .claude:
                let arg = event.scriptArg.map { " \($0)" } ?? ""
                return "\(python) '\(scriptPath)'\(arg) --agent \(agentName)"
            case .cursor:
                return "\(python) '\(scriptPath)'"
            }
        }
    }

    /// Add (or refresh) our hook for every managed event, dropping any prior copy of ours
    /// first so repeat installs stay idempotent, and preserving every foreign hook.
    static func applyingHook(to settings: [String: Any], format: Format, events: [HookEvent],
                             marker: String, command: (HookEvent, Format) -> String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in events {
            let cmd = command(spec, format)
            switch format {
            case .claude:
                var groups = (hooks[spec.name] as? [[String: Any]] ?? []).filter { group in
                    !((group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"], marker) })
                }
                var entry: [String: Any] = ["type": "command", "command": cmd]
                if let t = spec.timeout { entry["timeout"] = t }
                var group: [String: Any] = ["hooks": [entry]]
                if let matcher = spec.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[spec.name] = groups
            case .cursor:
                var entries = (hooks[spec.name] as? [[String: Any]] ?? []).filter { !isOurs($0["command"], marker) }
                var entry: [String: Any] = ["command": cmd]
                if let t = spec.timeout { entry["timeout"] = t }
                entries.append(entry)
                hooks[spec.name] = entries
            }
        }
        settings["hooks"] = hooks
        if format == .cursor { settings["version"] = settings["version"] ?? 1 }
        return settings
    }

    /// Remove only the hooks we own, leaving every foreign hook (and unrelated keys) intact.
    static func removingHook(from settings: [String: Any], format: Format, marker: String) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in Array(hooks.keys) {
            switch format {
            case .claude:
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                let kept = groups.compactMap { group -> [String: Any]? in
                    let cmds = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"], marker) }
                    if cmds.isEmpty { return nil }
                    var g = group; g["hooks"] = cmds; return g
                }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            case .cursor:
                let kept = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0["command"], marker) }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    // MARK: Helpers

    private static func isOurs(_ command: Any?, _ marker: String) -> Bool {
        (command as? String)?.contains(marker) == true
    }

    private func settingsReferencesScript() -> Bool {
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        let path = installedScriptURL.path
        for (_, value) in hooks {
            switch format {
            case .claude:
                for group in (value as? [[String: Any]] ?? []) {
                    for cmd in (group["hooks"] as? [[String: Any]] ?? []) {
                        if (cmd["command"] as? String)?.contains(path) == true { return true }
                    }
                }
            case .cursor:
                for entry in (value as? [[String: Any]] ?? []) {
                    if (entry["command"] as? String)?.contains(path) == true { return true }
                }
            }
        }
        return false
    }

    private func bundledScriptURL() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent(scriptResource)
            if fm.fileExists(atPath: u.path) { return u }
        }
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for candidate in [exeDir.appendingPathComponent(scriptResource),
                          exeDir.appendingPathComponent("../../Scripts/\(scriptResource)")] {
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func resolvePython() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeSettings(_ settings: [String: Any]) -> Bool {
        do {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            NSLog("GenericHookInstaller[\(agentName)].writeSettings failed: \(error)")
            return false
        }
    }
}
