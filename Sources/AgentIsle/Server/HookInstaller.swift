import Foundation

/// Thin façade over the generalized `CLIIntegration.claude` hook installer, kept for the
/// call sites (menu, settings, island) that predate the registry. All logic now lives in
/// `GenericHookInstaller`; this just forwards to the Claude Code integration so the API and
/// behavior (including the `CLAUDE_CONFIG_DIR` override) are unchanged.
enum HookInstaller {
    /// True if the user has Claude Code (a `~/.claude` config dir, or `$CLAUDE_CONFIG_DIR`).
    static func hasClaudeCode() -> Bool { CLIIntegration.claude.hasCLI() }

    static func isInstalled() -> Bool { CLIIntegration.claude.hook?.isInstalled() ?? false }

    @discardableResult
    static func install() -> Bool { CLIIntegration.claude.hook?.install() ?? false }

    @discardableResult
    static func uninstall() -> Bool { CLIIntegration.claude.hook?.uninstall() ?? true }
}
