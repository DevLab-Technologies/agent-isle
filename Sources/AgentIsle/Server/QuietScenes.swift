import AppKit
import CoreGraphics

/// Watches the environment for "quiet scenes" — moments the user almost certainly does not
/// want to be interrupted — and reports whether any is active so alerts can be muted.
///
/// Three signals, all best-effort:
///  1. macOS Focus / Do Not Disturb (read from the user's notification-assertion defaults).
///  2. Screen locked (`com.apple.screenIsLocked` / `screenIsUnlocked` distributed notes).
///  3. Screen recording or sharing (a `CGWindowList` heuristic).
///
/// The observer only tracks state and computes `isSuppressing`; it does not touch the
/// `SoundPlayer`/`Notifier` gates directly. When state changes it calls `onChange`, and
/// `AppSettings.applyMuting()` folds `isSuppressing` into those existing `enabled` gates —
/// so a quiet scene mutes output while the UI keeps updating.
@MainActor
final class QuietScenes {
    static let shared = QuietScenes()

    /// Fired whenever the effective quiet state may have changed. Set by the app after
    /// launch (nil during `AppSettings` init, so config pushes there are side-effect free).
    var onChange: (() -> Void)?

    // MARK: Config (pushed from AppSettings, mirrors how sound/notif prefs are pushed)
    private(set) var masterEnabled = false
    private var honorFocus = true
    private var honorLock = true
    private var honorScreenSharing = true

    // MARK: Detected raw state
    private(set) var focusActive = false
    private(set) var screenLocked = false
    private(set) var screenSharing = false

    private var started = false
    private var pollTimer: Timer?

    private init() {}

    /// The single question the muting logic asks: should alerts be silenced right now?
    var isSuppressing: Bool {
        guard masterEnabled else { return false }
        return (honorFocus && focusActive)
            || (honorLock && screenLocked)
            || (honorScreenSharing && screenSharing)
    }

    // MARK: Configuration

    /// Push the user's preferences in. Side-effect free during `AppSettings` init because
    /// `onChange` is still nil then; called again on every preference change afterward.
    func configure(masterEnabled: Bool, honorFocus: Bool, honorLock: Bool, honorScreenSharing: Bool) {
        self.masterEnabled = masterEnabled
        self.honorFocus = honorFocus
        self.honorLock = honorLock
        self.honorScreenSharing = honorScreenSharing
        onChange?()
    }

    // MARK: Lifecycle

    /// Begin observing. Idempotent. Registers the lock notifications, does an initial poll,
    /// and starts the periodic poll for Focus + screen-sharing (neither posts a note).
    func start() {
        guard !started else { return }
        started = true

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenDidLock),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenDidUnlock),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        refreshPolledState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPolledState() }
        }
    }

    @objc private func screenDidLock() {
        Task { @MainActor in self.setScreenLocked(true) }
    }

    @objc private func screenDidUnlock() {
        Task { @MainActor in self.setScreenLocked(false) }
    }

    private func setScreenLocked(_ locked: Bool) {
        guard screenLocked != locked else { return }
        screenLocked = locked
        onChange?()
    }

    /// Re-read the signals that don't post notifications (Focus + screen sharing).
    private func refreshPolledState() {
        let newFocus = Self.isFocusActive()
        let newSharing = Self.isScreenBeingCaptured()
        guard newFocus != focusActive || newSharing != screenSharing else { return }
        focusActive = newFocus
        screenSharing = newSharing
        onChange?()
    }

    // MARK: Detection

    /// Best-effort Focus / Do Not Disturb read. macOS stores the current assertion under the
    /// DoNotDisturb / Focus preference domains; the key moved across releases, so we probe a
    /// couple of known shapes and treat any present assertion as "Focus on". Not sandbox-safe
    /// and undocumented — hence best-effort, and worth on-device verification.
    static func isFocusActive() -> Bool {
        // Ventura+ Focus state lives in the Assertions plist under the DoNotDisturb group
        // container; a non-empty "senderDefinedDataDictionary"/assertion list means a Focus
        // is engaged. Fall back to the legacy `doNotDisturb` bool on older systems.
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let assertions = home.appendingPathComponent(
            "Library/DoNotDisturb/DB/Assertions.json")
        if let data = try? Data(contentsOf: assertions),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let records = obj["data"] as? [[String: Any]] {
            for record in records {
                if let store = record["storeAssertionRecords"] as? [[String: Any]], !store.isEmpty {
                    return true
                }
            }
        }
        // Legacy Do Not Disturb flag (pre-Focus).
        if let dnd = CFPreferencesCopyValue(
            "doNotDisturb" as CFString,
            "com.apple.notificationcenterui" as CFString,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool {
            return dnd
        }
        return false
    }

    /// Heuristic for screen recording / sharing: scan the on-screen window list for windows
    /// owned by known capture/conferencing tools. `CGWindowListCopyWindowInfo` needs no
    /// special entitlement. This is intentionally a heuristic — there is no public API that
    /// reliably reports "my screen is being recorded" — so it can miss or over-report and
    /// deserves on-device verification.
    static func isScreenBeingCaptured() -> Bool {
        // Window owners whose on-screen presence strongly implies an active capture or
        // recording session. Kept to unambiguous signals: the system record toolbar and
        // dedicated recording tools. Conferencing apps are excluded — an idle Zoom window
        // is not a capture — so this under-reports rather than muting during normal calls.
        let captureOwners: Set<String> = [
            "screencaptureui",   // macOS screenshot/record toolbar (⇧⌘5)
            "OBS Studio", "obs",
            "Loom",
            "ScreenFlow", "Kap", "CleanShot X",
        ]

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in list {
            if let owner = window[kCGWindowOwnerName as String] as? String,
               captureOwners.contains(owner) {
                return true
            }
        }
        return false
    }
}
