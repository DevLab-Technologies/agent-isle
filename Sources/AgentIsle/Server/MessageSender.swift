import AppKit
import ApplicationServices

/// Delivers a typed message into a running agent session's terminal.
///
/// Claude Code has no API to inject a prompt, so this drives the host terminal:
///   • iTerm2 / Terminal.app  → their AppleScript dictionaries (`write text` / `do script`),
///     which need no extra permission and target the terminal's current session directly.
///   • everything else        → focus the app, then synthesize the keystrokes (types the
///     text via a CGEvent and presses Return). This needs macOS Accessibility permission.
@MainActor
enum MessageSender {
    enum SendError: Error {
        case accessibilityDenied
        case scriptFailed(String)

        /// A short, user-facing explanation shown under the input bar.
        var userMessage: String {
            switch self {
            case .accessibilityDenied:
                return "Grant Accessibility access to Agent Isle in System Settings › Privacy, then try again."
            case .scriptFailed(let detail):
                return "Couldn't send: \(detail)"
            }
        }
    }

    // Bundle identifiers we can script directly instead of simulating keystrokes.
    private static let iterm = "com.googlecode.iterm2"
    private static let terminal = "com.apple.Terminal"

    /// Send `text` into `session`. The completion runs on the main actor.
    static func send(_ text: String, to session: AgentSession,
                     completion: @escaping (Result<Void, SendError>) -> Void) {
        // Single-line prompt: strip any stray newlines so terminal delivery is clean.
        let line = text.replacingOccurrences(of: "\n", with: " ")
        let bundle = session.terminalBundleID ?? bundleID(forLabel: session.terminal)

        switch bundle {
        case iterm:
            completion(runAppleScript(itermScript(line)))
        case terminal:
            completion(runAppleScript(terminalScript(line)))
        default:
            sendViaKeystrokes(line, to: session, completion: completion)
        }
    }

    // MARK: - AppleScript paths

    // Target by bundle id, not name — iTerm's AppleScript name varies across installs
    // ("iTerm" vs "iTerm2"), whereas the bundle id is stable.
    private static func itermScript(_ text: String) -> String {
        """
        tell application id "\(iterm)"
            activate
            tell current window
                tell current session to write text "\(escape(text))"
            end tell
        end tell
        """
    }

    private static func terminalScript(_ text: String) -> String {
        // `front window` errors if Terminal has no open window — surface a clear reason
        // instead of the raw AppleScript error.
        """
        tell application id "\(terminal)"
            activate
            if (count of windows) is 0 then error "no open Terminal window for this session"
            do script "\(escape(text))" in front window
        end tell
        """
    }

    private static func runAppleScript(_ source: String) -> Result<Void, SendError> {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.scriptFailed("invalid script"))
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo, let msg = errorInfo[NSAppleScript.errorMessage] as? String {
            return .failure(.scriptFailed(msg))
        }
        return .success(())
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Keystroke fallback

    private static func sendViaKeystrokes(_ text: String, to session: AgentSession,
                                          completion: @escaping (Result<Void, SendError>) -> Void) {
        guard ensureAccessibility() else {
            completion(.failure(.accessibilityDenied))
            return
        }
        // Bring the session's terminal forward, then type once it's frontmost.
        Jumper.jump(to: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            typeString(text)
            pressReturn()
            completion(.success(()))
        }
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

    /// Map a terminal display label to a bundle id for the AppleScript-capable apps.
    private static func bundleID(forLabel label: String) -> String? {
        switch label {
        case "iTerm", "iTerm2": return iterm
        case "Terminal": return terminal
        default: return nil
        }
    }
}
