import AppKit
import ApplicationServices

/// The single gate for macOS Accessibility permission, which the keystroke delivery path in
/// `MessageSender` needs.
///
/// `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` is not a one-time
/// system prompt: every call while untrusted pops a dialog and opens System Settings ▸
/// Privacy & Security ▸ Accessibility. Calling it on each send meant that any user whose
/// grant doesn't actually apply to the running copy — the common case after the app is moved,
/// updated, or re-signed, where the switch still reads "on" but the grant is keyed to a code
/// identity that no longer matches — had System Settings thrown at them again and again.
///
/// So the prompt fires at most once, is remembered across launches, and is forgotten again
/// the moment we observe real trust (so a later genuine loss of the grant can still prompt).
/// After that first ask, failures surface as an in-UI explanation with an explicit button,
/// leaving the trip to System Settings the user's choice rather than ours.
@MainActor
enum AccessibilityPermission {
    /// Live, never-prompting trust check.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Outcome of a trust check.
    enum Outcome {
        /// Trusted — synthetic events may be posted.
        case trusted
        /// Untrusted, and macOS was asked to show its prompt (it stays silent if the app is
        /// already listed under Accessibility, so the caller must not promise a window).
        case prompted
        /// Untrusted, and we already asked in an earlier attempt — prompting again would only
        /// reopen System Settings, so the caller explains the options instead.
        case alreadyAsked
    }

    /// The rule, free of system state so it can be tested: prompt only when untrusted and we
    /// haven't asked before.
    static func decide(isTrusted: Bool, alreadyAsked: Bool) -> Outcome {
        if isTrusted { return .trusted }
        return alreadyAsked ? .alreadyAsked : .prompted
    }

    /// Fold an outcome into the "already asked" flag, returning whether the caller must now
    /// show the macOS prompt. Split out from `check()` so the ask-once-and-reset bookkeeping
    /// is testable without touching TCC or opening System Settings.
    static func record(_ outcome: Outcome, alreadyAsked: inout Bool) -> Bool {
        switch outcome {
        case .trusted:
            // Trust observed: forget the ask so a future genuine loss of the grant can prompt.
            alreadyAsked = false
            return false
        case .prompted:
            alreadyAsked = true
            return true
        case .alreadyAsked:
            return false
        }
    }

    /// Check trust, showing the system prompt at most once. Never reopens System Settings on
    /// repeat attempts.
    static func check() -> Outcome {
        let wasAsked = AppSettings.shared.accessibilityPromptShown
        var asked = wasAsked
        let outcome = decide(isTrusted: isTrusted, alreadyAsked: asked)
        let shouldPrompt = record(outcome, alreadyAsked: &asked)
        if asked != wasAsked {
            AppSettings.shared.accessibilityPromptShown = asked
        }
        recordDeniedStreak(trusted: outcome == .trusted)
        if shouldPrompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return outcome
    }

    /// Drop a recorded ask whenever the app is actually trusted. Called at launch as well as
    /// from `check()`: a user whose sessions all take the AppleScript path never reaches
    /// `check()`, and would otherwise carry the flag forever — so if the grant were later
    /// invalidated they'd get no prompt at all on their next keystroke send.
    static func forgetAskIfTrusted() {
        guard AppSettings.shared.accessibilityPromptShown, isTrusted else { return }
        AppSettings.shared.accessibilityPromptShown = false
        AppSettings.shared.accessibilityDeniedStreak = 0
    }

    /// The rule, free of system state so it can be tested: reset the streak once trust is
    /// observed, otherwise grow it.
    static func nextDeniedStreak(current: Int, trusted: Bool) -> Int {
        trusted ? 0 : current + 1
    }

    /// Update the consecutive-denial streak, skipping the write on the common already-trusted,
    /// already-zero path — the only case where `nextDeniedStreak` returns the same value it
    /// was given.
    private static func recordDeniedStreak(trusted: Bool) {
        let current = AppSettings.shared.accessibilityDeniedStreak
        let next = nextDeniedStreak(current: current, trusted: trusted)
        if next != current {
            AppSettings.shared.accessibilityDeniedStreak = next
        }
    }

    /// The rule, free of system state so it can be tested: only warn of a stale grant once
    /// several attempts in a row have found the app untrusted. A single `.alreadyAsked`
    /// outcome isn't enough on its own — its preceding `.prompted` call may never have shown
    /// a dialog (see `Outcome.prompted`), so the very next attempt shouldn't assume the user
    /// already had a chance to react.
    static func warnsStaleGrant(streak: Int) -> Bool {
        streak > 2
    }

    /// True once `warnsStaleGrant` for the persisted streak — see its doc comment.
    static var shouldWarnStaleGrant: Bool {
        warnsStaleGrant(streak: AppSettings.shared.accessibilityDeniedStreak)
    }

    /// Open the Accessibility pane — only ever from an explicit user action.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
