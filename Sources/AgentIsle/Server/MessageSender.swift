import AppKit
import os

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
        /// Not trusted for Accessibility. `staleGrantSuspected` is NOT "macOS was already
        /// asked" — a single ask doesn't prove a dialog ever appeared (see
        /// `AccessibilityPermission.Outcome.prompted`) — it's true once repeated denials
        /// (`AccessibilityPermission.shouldWarnStaleGrant`) make a stale grant likely enough
        /// to suggest removing and re-adding the app.
        case accessibilityDenied(staleGrantSuspected: Bool)
        case automationDenied(String)
        case couldNotFocus(String)
        case scriptFailed(String)

        /// A short, user-facing explanation shown under the input bar.
        var userMessage: String {
            switch self {
            case .accessibilityDenied(let staleGrantSuspected):
                // Neither message claims more than we know: macOS shows no prompt at all when
                // the app is already listed under Accessibility, and a still-untrusted second
                // attempt may just mean the user hasn't finished granting it yet.
                return staleGrantSuspected
                    ? "Still no Accessibility permission for Agent Isle. Turn it on in Accessibility settings — if it already looks enabled, this isn't the copy that was granted, so remove Agent Isle there, add this one back, and relaunch."
                    : "Agent Isle needs Accessibility permission to type into your session. Turn it on in Accessibility settings, then send again."
            case .automationDenied(let app):
                return "Allow Agent Isle to control \(app) in System Settings › Privacy › Automation, then try again."
            case .couldNotFocus(let app):
                return "Couldn't bring \(app) forward to deliver the answer — focus it and try again."
            case .scriptFailed(let detail):
                return "Couldn't send: \(detail)"
            }
        }
    }

    // Bundle identifiers we can script directly instead of simulating keystrokes.
    private static let iterm = "com.googlecode.iterm2"
    private static let terminal = "com.apple.Terminal"

    // MARK: - Stale-completion guarding

    /// Per-channel counter guarding against a stale, slow-to-complete send (e.g. the keystroke
    /// path's frontmost-app poll in `waitUntilFrontmost`, which can take up to 1.5s) actually
    /// running its side effect — or reporting its outcome — after a *later* send on the same
    /// channel has already resolved. A plain `@MainActor`-isolated dictionary isn't enough: the
    /// AppleScript path checks currency from a background queue (see `runScriptOffMain`), right
    /// before actually running the script, not just around the completion — the guard has to
    /// stop the *side effect*, not merely filter which outcome gets reported, or two overlapping
    /// sends on the same channel could both actually type/script into the terminal with only the
    /// newer one's result ever shown. `OSAllocatedUnfairLock` makes the store itself genuinely
    /// `Sendable`, so the functions below need no actor isolation and are safe to call from any
    /// thread (a caller only needs a `Hashable` value that names the channel — e.g. a
    /// per-session, per-purpose key — not its own generation bookkeeping).
    nonisolated private static let generations = OSAllocatedUnfairLock<[AnyHashable: Int]>(initialState: [:])

    nonisolated static func beginAttempt(on channel: AnyHashable) -> Int {
        generations.withLock { values in
            let next = (values[channel] ?? 0) + 1
            values[channel] = next
            return next
        }
    }

    nonisolated static func isCurrentAttempt(_ generation: Int, on channel: AnyHashable) -> Bool {
        generations.withLock { $0[channel] == generation }
    }

    /// Forget a channel's tracked attempt. Call when the channel's owner (e.g. a removed
    /// session) can no longer act on an outcome, so `generations` doesn't grow forever.
    nonisolated static func forgetChannel(_ channel: AnyHashable) {
        generations.withLock { $0[channel] = nil }
    }

    /// Forget every tracked channel at once — cheaper than forgetting each individually when
    /// all owning state is being reset together (e.g. `SessionStore.clearAll()`).
    nonisolated static func forgetAllChannels() {
        generations.withLock { $0.removeAll() }
    }

    /// Send `text` into `session` on `channel`. If a later `send` call on the same `channel`
    /// starts before this one resolves, this call is dropped as soon as that's detected —
    /// before its side effect (typing, or running the AppleScript) runs, not just before its
    /// completion — so callers only ever see, and only the terminal only ever receives, the
    /// outcome of their most recent request on a given channel. The completion runs on the
    /// main actor.
    static func send(_ text: String, to session: AgentSession, channel: AnyHashable,
                     completion: @escaping (Result<Void, SendError>) -> Void) {
        let generation = beginAttempt(on: channel)
        let guarded: (Result<Void, SendError>) -> Void = { result in
            guard isCurrentAttempt(generation, on: channel) else { return }
            completion(result)
        }

        // Single-line prompt: strip any stray newlines so terminal delivery is clean.
        let line = text.replacingOccurrences(of: "\n", with: " ")
        let bundle = session.terminalBundleID ?? bundleID(forLabel: session.terminal)

        switch bundle {
        case iterm:
            runScriptOffMain(itermScript(line), app: "iTerm2", generation: generation, channel: channel,
                             completion: guarded)
        case terminal:
            runScriptOffMain(terminalScript(line), app: "Terminal", generation: generation, channel: channel,
                             completion: guarded)
        default:
            sendViaKeystrokes(line, to: session, generation: generation, channel: channel, completion: guarded)
        }
    }

    // MARK: - AppleScript paths

    /// Run AppleScript on a background queue, delivering the result back on the main actor.
    /// `NSAppleScript.executeAndReturnError` blocks its thread — potentially for a long time
    /// on the one-time macOS Automation permission prompt, or if the target app is slow —
    /// so running it on the main thread would freeze the whole UI (and with it the Quit
    /// menu, leaving no way to exit this accessory app). Off-main, the UI stays responsive.
    nonisolated private static func runScriptOffMain(
        _ source: String, app: String, generation: Int, channel: AnyHashable,
        completion: @escaping (Result<Void, SendError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Re-check right before the script actually runs, not just before reporting the
            // result: a superseded attempt must not touch the terminal at all.
            guard isCurrentAttempt(generation, on: channel) else { return }
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

    nonisolated private static func terminalScript(_ text: String) -> String {
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

    // MARK: - Keystroke fallback

    private static func sendViaKeystrokes(_ text: String, to session: AgentSession,
                                          generation: Int, channel: AnyHashable,
                                          completion: @escaping (Result<Void, SendError>) -> Void) {
        // Guard before any side effect at all, not just before typing: AccessibilityPermission
        // .check() and Jumper.jump(to:) below have their own real effects (persisted streak
        // state, a possible System Settings prompt, stealing focus) that a superseded attempt
        // must not trigger either.
        guard isCurrentAttempt(generation, on: channel) else { return }
        switch AccessibilityPermission.check() {
        case .trusted:
            break
        case .prompted:
            completion(.failure(.accessibilityDenied(staleGrantSuspected: false)))
            return
        case .alreadyAsked:
            completion(.failure(.accessibilityDenied(staleGrantSuspected: AccessibilityPermission.shouldWarnStaleGrant)))
            return
        }
        // Bring the session's app forward, then type only once it is actually frontmost.
        // A fixed delay races the async activation (`NSWorkspace.openApplication` returns
        // before the app is front), so keystrokes could land in whatever app happened to
        // have focus — the answer would silently go nowhere while we reported success.
        // Waiting for real focus, and failing if it never comes, keeps "sent" honest.
        Jumper.jump(to: session)
        waitUntilFrontmost(Jumper.targetBundleID(for: session)) { focused in
            // Re-check right before actually typing, not just before reporting the result: a
            // superseded attempt must not touch the terminal at all (see `generations`).
            guard isCurrentAttempt(generation, on: channel) else { return }
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
