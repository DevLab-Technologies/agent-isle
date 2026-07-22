import Foundation

/// Thin façade over the generalized `CLIIntegration.cursor` hook installer, kept for the
/// call sites (menu, settings, island) that predate the registry. All logic now lives in
/// `GenericHookInstaller`, which edits `~/.cursor/hooks.json` in place; this just forwards.
enum CursorHookInstaller {
    /// True if the user has Cursor (a `~/.cursor` config dir).
    static func hasCursor() -> Bool { CLIIntegration.cursor.hasCLI() }

    static func isInstalled() -> Bool { CLIIntegration.cursor.hook?.isInstalled() ?? false }

    @discardableResult
    static func install() -> Bool { CLIIntegration.cursor.hook?.install() ?? false }

    @discardableResult
    static func uninstall() -> Bool { CLIIntegration.cursor.hook?.uninstall() ?? true }
}
