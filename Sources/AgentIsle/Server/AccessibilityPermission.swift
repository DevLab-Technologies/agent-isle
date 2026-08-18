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
        /// Untrusted, and macOS was just asked to show its prompt (System Settings opened).
        case prompted
        /// Untrusted, and we already asked in an earlier attempt — prompting again would only
        /// reopen System Settings. Practically always a grant that belongs to a different copy
        /// of the app, so the caller should explain how to re-add this one instead.
        case alreadyAsked
    }

    /// The rule, free of system state so it can be tested: prompt only when untrusted and we
    /// haven't asked before.
    static func decide(isTrusted: Bool, alreadyAsked: Bool) -> Outcome {
        if isTrusted { return .trusted }
        return alreadyAsked ? .alreadyAsked : .prompted
    }

    /// Check trust, showing the system prompt at most once. Never reopens System Settings on
    /// repeat attempts.
    static func check() -> Outcome {
        let outcome = decide(isTrusted: isTrusted,
                             alreadyAsked: AppSettings.shared.accessibilityPromptShown)
        switch outcome {
        case .trusted:
            // Trust observed: forget the ask so a future genuine loss of the grant can prompt.
            if AppSettings.shared.accessibilityPromptShown {
                AppSettings.shared.accessibilityPromptShown = false
            }
        case .prompted:
            AppSettings.shared.accessibilityPromptShown = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .alreadyAsked:
            break
        }
        return outcome
    }

    /// Open the Accessibility pane — only ever from an explicit user action.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
