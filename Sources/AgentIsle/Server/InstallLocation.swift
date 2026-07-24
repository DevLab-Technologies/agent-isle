import AppKit

/// Detects when the app is running from a location where macOS won't let permission grants
/// (Accessibility in particular) take effect, and offers to move it into /Applications.
///
/// A downloaded, quarantined app launched from ~/Downloads is run under Gatekeeper *App
/// Translocation*: macOS mounts a read-only, randomized copy and runs it from a path that
/// changes every launch. `AXIsProcessTrusted()` then never becomes true no matter how many
/// times the user toggles the System Settings switch — the grant is keyed to a code identity
/// at a path that no longer exists. That is the root cause of "Agent Isle asks for
/// Accessibility even though I already granted it," and why answers typed into a session
/// can't be delivered. Moving the app into /Applications clears translocation and lets the
/// grant stick.
@MainActor
enum InstallLocation {
    /// The canonical install directory we move the app into.
    private static let applications = "/Applications"

    /// The shipped app's bundle id. Local dev bundles use a distinct id (see `bundle.sh`) and
    /// are meant to run in place from the build directory, so they never get the relocate offer.
    private static let shippedBundleID = "com.devlab.agentisle"

    /// True when Gatekeeper is running us from a translocated, read-only mount.
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// True when the running bundle already lives in a system or user Applications folder,
    /// where permissions persist across launches.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix(applications + "/") { return true }
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return path.hasPrefix(userApps + "/")
    }

    /// If the app is translocated or outside /Applications, offer to relocate it there and
    /// relaunch. Translocation always re-offers (nothing works until it's fixed); a plain
    /// out-of-Applications launch is offered once and then remembered.
    static func offerToRelocateIfNeeded() {
        // Only the shipped app relocates; dev builds run in place from build/.
        guard Bundle.main.bundleIdentifier == shippedBundleID else { return }
        guard !isInApplicationsFolder else { return }
        if !isTranslocated && AppSettings.shared.relocationPromptSuppressed { return }

        let alert = NSAlert()
        alert.messageText = "Move Agent Isle to Applications?"
        alert.informativeText = isTranslocated
            ? """
              Agent Isle is running from a temporary, read-only copy (macOS App \
              Translocation). Accessibility and other permissions can't take effect here, so \
              answers from the notch can't reach your sessions — and Agent Isle keeps asking \
              for Accessibility even after you grant it. Move it to Applications and relaunch \
              to fix this.
              """
            : """
              For permissions like Accessibility to stick — needed to deliver answers into \
              your sessions — Agent Isle should run from your Applications folder. Move it \
              there and relaunch now?
              """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: isTranslocated ? "Quit" : "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relocateAndRelaunch()
        } else if isTranslocated {
            // Declined while translocated: nothing works from here, so quit rather than run
            // in a state where the user's answers silently go nowhere.
            NSApp.terminate(nil)
        } else {
            AppSettings.shared.relocationPromptSuppressed = true
        }
    }

    /// Copy the running bundle into /Applications, strip quarantine (so the copy isn't
    /// translocated in turn), launch it, and terminate this instance. On any failure, explain
    /// how to move it manually and leave the current instance running.
    private static func relocateAndRelaunch() {
        let fm = FileManager.default
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: applications).appendingPathComponent(src.lastPathComponent)

        do {
            // Replace any existing copy so an older install doesn't shadow the move.
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } catch {
            reportFailure(error)
            return
        }

        // Clear the quarantine flag on the copy; otherwise macOS may translocate it too and
        // we'd be right back where we started. Best-effort — the move itself already helps.
        stripQuarantine(at: dst)

        // Launch the relocated copy, then quit this one. The fresh instance force-terminates
        // older copies on launch, so there's no fight over the event-server port.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: dst, configuration: config) { _, error in
            Task { @MainActor in
                if let error { reportFailure(error); return }
                NSApp.terminate(nil)
            }
        }
    }

    private static func stripQuarantine(at url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func reportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't move Agent Isle"
        alert.informativeText = """
        Please drag “Agent Isle.app” into your Applications folder manually, then relaunch it. \
        (\(error.localizedDescription))
        """
        alert.runModal()
    }
}
