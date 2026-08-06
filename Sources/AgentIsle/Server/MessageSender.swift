import AppKit
import ApplicationServices

/// Delivers a typed message into a running agent session's terminal.
///
/// Claude Code has no API to inject a prompt, so this drives the host terminal:
///   • iTerm2           → AppleScript `write text` on the current session (no Accessibility
///     prompt; needs Automation permission for iTerm).
///   • everything else  → focus the app, then synthesize keystrokes (CGEvent unicode + Return).
///     This needs macOS Accessibility permission.
///
/// Terminal.app is intentionally **not** scripted with `do script`: that command runs a
/// shell line (often in a new tab) rather than typing into the live agent session.
@MainActor
enum MessageSender {
    enum SendError: Error {
        case accessibilityDenied
        case automationDenied(String)
        case couldNotFocus(String)
        case scriptFailed(String)

        /// A short, user-facing explanation shown under the input bar.
        var userMessage: String {
            switch self {
            case .accessibilityDenied:
                return "Grant Accessibility to Agent Isle in System Settings › Privacy. If it already looks enabled, remove it there, re-add this copy, and relaunch."
            case .automationDenied(let app):
                return "Allow Agent Isle to control \(app) in System Settings › Privacy › Automation, then try again."
            case .couldNotFocus(let app):
                return "Couldn't bring \(app) forward to deliver the answer — focus it and try again."
            case .scriptFailed(let detail):
                return "Couldn't send: \(detail)"
            }
        }
    }

    /// Only iTerm exposes a safe "type into current session" AppleScript verb.
    /// `nonisolated` so AppleScript helpers (off the main actor) can embed the id.
    nonisolated private static let iterm = "com.googlecode.iterm2"

    /// Send `text` into `session`. The completion runs on the main actor.
    static func send(_ text: String, to session: AgentSession,
                     completion: @escaping (Result<Void, SendError>) -> Void) {
        // Single-line prompt: strip any stray newlines so terminal delivery is clean.
        let line = text.replacingOccurrences(of: "\n", with: " ")
        let bundle = session.terminalBundleID ?? bundleID(forLabel: session.terminal)

        if bundle == iterm {
            runScriptOffMain(itermScript(line), app: "iTerm2", completion: completion)
        } else {
            // Terminal.app, Ghostty, Warp, VS Code, Claude Desktop, …
            sendViaKeystrokes(line, to: session, completion: completion)
        }
    }

    // MARK: - AppleScript paths

    /// Run AppleScript on a background queue, delivering the result back on the main actor.
    /// `NSAppleScript.executeAndReturnError` blocks its thread — potentially for a long time
    /// on the one-time macOS Automation permission prompt, or if the target app is slow —
    /// so running it on the main thread would freeze the whole UI (and with it the Quit
    /// menu, leaving no way to exit this accessory app). Off-main, the UI stays responsive.
    nonisolated private static func runScriptOffMain(
        _ source: String, app: String,
        completion: @escaping (Result<Void, SendError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runAppleScript(source, app: app)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Target by bundle id, not name — iTerm's AppleScript name varies across installs
    // ("iTerm" vs "iTerm2"), whereas the bundle id is stable.
    nonisolated private static func itermScript(_ text: String) -> String {
        """
        tell application id "\(iterm)"
            activate
            tell current window
                tell current session to write text "\(escape(text))"
            end tell
        end tell
        """
    }

    nonisolated private static func runAppleScript(_ source: String, app: String) -> Result<Void, SendError> {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed("invalid script"))
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let num = errorInfo[NSAppleScript.errorNumber] as? Int
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            // Automation control of the target app hasn't been granted (System Settings ›
            // Privacy › Automation). Match both the -1743 (errAEEventNotPermitted) code and the
            // "Not authorized to send Apple events" text — the latter also appears before the
            // usage-description consent is granted — and surface an actionable hint.
            if num == -1743 || msg.localizedCaseInsensitiveContains("not authorized to send apple events") {
                return .failure(.automationDenied(app))
            }
            return .failure(.scriptFailed(msg))
        }
        return .success(())
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    nonisolated private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Keystroke delivery

    private static func sendViaKeystrokes(_ text: String, to session: AgentSession,
                                          completion: @escaping (Result<Void, SendError>) -> Void) {
        guard ensureAccessibility() else {
            completion(.failure(.accessibilityDenied))
            return
        }
        // Bring the session's app forward, then type only once it is actually frontmost.
        // A fixed delay races the async activation (`NSWorkspace.openApplication` returns
        // before the app is front), so keystrokes could land in whatever app happened to
        // have focus — the answer would silently go nowhere while we reported success.
        // Waiting for real focus, and failing if it never comes, keeps "sent" honest.
        Jumper.jump(to: session)
        waitUntilFrontmost(Jumper.targetBundleID(for: session)) { focused in
            guard focused else {
                completion(.failure(.couldNotFocus(session.terminal)))
                return
            }
            typeString(text)
            pressReturn()
            completion(.success(()))
        }
    }

    /// Poll until the app with `bundleID` is frontmost — async activation makes any fixed
    /// delay unreliable. Calls back with `true` once it's front (after a short beat so it can
    /// focus its input field), or `false` if it isn't within `timeout`. When the target bundle
    /// is unknown (an open-URL jump rule) we can't verify focus, so fall back to a short
    /// settle delay and assume it landed.
    private static func waitUntilFrontmost(_ bundleID: String?,
                                           timeout: TimeInterval = 1.5,
                                           completion: @escaping (Bool) -> Void) {
        guard let bundleID else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion(true) }
            return
        }
        let start = Date()
        func poll() {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(true) }
            } else if Date().timeIntervalSince(start) >= timeout {
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
    }

    /// Returns true if we may post synthetic events; otherwise triggers the one-time
    /// system prompt so the user can grant access.
    private static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        return false
    }

    /// Maximum UTF-16 units per synthesized event. A single event carrying a long
    /// unicode string is delivered unreliably — many apps drop everything past a small
    /// buffer — so the text is posted in small chunks split on grapheme boundaries.
    private static let maxChunkUnits = 16

    private static func typeString(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var buffer: [Character] = []
        var units = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var utf16 = Array(String(buffer).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
            buffer.removeAll(keepingCapacity: true)
            units = 0
        }

        for ch in text {
            let n = ch.utf16.count
            if units + n > maxChunkUnits { flush() }   // never split a grapheme across events
            buffer.append(ch)
            units += n
        }
        flush()
    }

    private static func pressReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let returnKey: CGKeyCode = 36   // kVK_Return
        CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    /// Map a terminal display label to the iTerm bundle id when AppleScript delivery applies.
    private static func bundleID(forLabel label: String) -> String? {
        switch label {
        case "iTerm", "iTerm2": return iterm
        default: return nil
        }
    }
}
