import Foundation

/// Health checks for Agent Isle's CLI integrations. It answers, per integration, the
/// questions a user hits when "nothing shows up in the notch":
///
///  - Is the CLI even installed?
///  - Is our hook installed, and does its bridge point at the right `/event` port?
///  - Is the local event server actually listening on localhost:4711?
///  - Can we read the history the monitor-only agents rely on?
///
/// It's pure/synchronous and does no writes, so it's safe to run repeatedly from the
/// settings pane. `fix(_:)` reinstalls a single integration's hook.
enum IntegrationDoctor {
    enum Status { case ok, warn, fail, info }

    struct Check: Identifiable {
        let id = UUID()
        let title: String
        let status: Status
        let detail: String
    }

    struct Report: Identifiable {
        let agent: AgentKind
        let displayName: String
        let checks: [Check]
        /// True when a one-click "Fix" (reinstall the hook) can help.
        let fixable: Bool
        var id: String { agent.rawValue }
        /// Worst status across the checks, for the header badge.
        var overall: Status {
            if checks.contains(where: { $0.status == .fail }) { return .fail }
            if checks.contains(where: { $0.status == .warn }) { return .warn }
            if checks.contains(where: { $0.status == .info }) { return .info }
            return .ok
        }
    }

    /// The shared server-reachability check, surfaced once at the top of the settings pane.
    static func serverReachable() -> Bool {
        TCPProbe.canConnect(host: "127.0.0.1", port: EventServer.port)
    }

    /// Run every check for every *detected* integration. Undetected CLIs are omitted so the
    /// list stays about what the user actually has.
    static func run() -> [Report] {
        CLIIntegration.all.filter { $0.hasCLI() }.map(report(for:))
    }

    /// Reinstall a hook-capable integration's hook. Returns false if it isn't hook-capable
    /// or the install failed.
    @discardableResult
    static func fix(_ agent: AgentKind) -> Bool {
        guard let integration = CLIIntegration.all.first(where: { $0.agent == agent }),
              let hook = integration.hook else { return false }
        return hook.install()
    }

    // MARK: - Per-integration report

    private static func report(for integration: CLIIntegration) -> Report {
        var checks: [Check] = [
            Check(title: "CLI detected", status: .ok,
                  detail: "Found \(integration.configDir.path)"),
        ]

        var fixable = false
        if let hook = integration.hook {
            if hook.isInstalled() {
                let portOK = hook.scriptTargetsPort(EventServer.port)
                checks.append(Check(
                    title: "Hook installed",
                    status: portOK ? .ok : .warn,
                    detail: portOK
                        ? "Bridge registered and pointing at localhost:\(EventServer.port)."
                        : "Bridge is registered but does not target localhost:\(EventServer.port). Reinstall to repair."))
                fixable = !portOK
            } else {
                checks.append(Check(
                    title: "Hook installed",
                    status: .fail,
                    detail: "No Agent Isle hook in \(hook.settingsURL.lastPathComponent). Install it to approve tools from the notch."))
                fixable = true
            }
        } else {
            checks.append(Check(
                title: "Hook",
                status: .info,
                detail: monitorDetail(for: integration)))
        }

        if let history = integration.historyDir {
            let readable = FileManager.default.isReadableFile(atPath: history.path)
            checks.append(Check(
                title: "History readable",
                status: readable ? .ok : .info,
                detail: readable
                    ? "Reading activity from \(history.lastPathComponent)."
                    : "No activity directory yet at \(history.path). It appears once the CLI runs."))
        }

        return Report(agent: integration.agent,
                      displayName: integration.displayName,
                      checks: checks,
                      fixable: fixable)
    }

    private static func monitorDetail(for integration: CLIIntegration) -> String {
        switch integration.capability {
        case .liveChat:
            return "No hook mechanism; sessions and chat are read from history automatically."
        case .monitorOnly:
            return "No hook mechanism; detected only. Live monitoring isn't available yet."
        case .hook:
            return ""
        }
    }
}

/// Minimal blocking TCP connect probe, used only to confirm the loopback event server is
/// accepting connections. Against 127.0.0.1 a connect resolves immediately — it either
/// succeeds or is refused with no network wait — so no timeout plumbing is needed. No data
/// is sent, so it never creates a session.
private enum TCPProbe {
    static func canConnect(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
