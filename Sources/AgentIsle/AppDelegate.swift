import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SessionStore()
    private var notchWindow: NotchWindow?
    private var settingsWindow: NSWindow?
    private var geometryRefreshWork: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var ideWatcher: IdeWatcher?
    private var hookMenuItem: NSMenuItem?
    private var autoUpdateMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Single instance: replace any older copy so they don't fight over the event
        // server port (4711). A fresh launch wins.
        terminateOtherInstances()

        // Floating island over the notch. Suppressed in settings-capture mode so it
        // doesn't float over the settings window during a screenshot.
        let settingsCapture = ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] == "1"
        let window = NotchWindow(store: store, settings: AppSettings.shared)
        if !settingsCapture { window.orderFrontRegardless() }
        notchWindow = window

        setupStatusItem()

        // Settings window: opened from the gear menu; notch tuning rebuilds the island.
        NotificationCenter.default.addObserver(
            forName: .openAgentIsleSettings, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.openSettings() }
            }
        NotificationCenter.default.addObserver(
            forName: .agentIsleGeometryChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleGeometryRefresh() }
            }

        // Start the local event server so real agents can push updates.
        EventServer.shared = EventServer(store: store)
        EventServer.shared?.start()

        // Discover real sessions (local Claude Code + Grok/Copilot). No demo data by
        // default — a fresh install should never show fake sessions. Demo is opt-in
        // from the gear menu.
        // Dev/marketing: `AGENT_ISLE_DEMO=1` opens the island expanded with demo data so
        // the panel can be captured without wiring up a real agent. In this mode we skip
        // the live watcher (which would otherwise replace the demo with real sessions)
        // and the hook prompt.
        let demoLaunch = ProcessInfo.processInfo.environment["AGENT_ISLE_DEMO"] == "1"
        if demoLaunch {
            store.startDemo()
            store.isExpanded = true
        } else {
            ideWatcher = IdeWatcher(store: store)
            ideWatcher?.start()
        }

        // Dev/marketing: auto-open the settings window for capture.
        if ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openSettings() }
        }

        // Reposition if the display configuration changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.notchWindow?.reposition() }
            }

        // Offer to set up Claude Code approvals on launch (unless already done / opted out).
        if ProcessInfo.processInfo.environment["AGENT_ISLE_DEMO"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.maybePromptForHooks()
            }
        }

        // Check GitHub for a newer release and prompt / auto-install.
        Updater.shared.store = store
        Updater.shared.start()
    }

    /// Coalesce the burst of geometry changes a slider drag produces into one rebuild.
    private func scheduleGeometryRefresh() {
        geometryRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notchWindow?.refreshGeometry() }
        geometryRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    @objc private func openSettingsAction() { openSettings() }

    /// Open (or focus) the settings window, hosting the SwiftUI settings UI. The app is an
    /// accessory, so we activate it explicitly to bring a normal window to the front.
    func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(store)
                .environmentObject(AppSettings.shared)
            let controller = NSHostingController(rootView: root)
            let win = NSWindow(contentViewController: controller)
            win.title = "Agent Isle Settings"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(NSSize(width: 820, height: 620))
            win.isReleasedWhenClosed = false
            win.center()
            // In capture mode, anchor top-left so the center notch panel doesn't overlap.
            if ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] == "1", let scr = NSScreen.main {
                win.setFrameTopLeftPoint(NSPoint(x: scr.frame.minX + 40, y: scr.frame.maxY - 40))
                win.level = .floating   // stay above other apps for a clean screenshot
            }
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Terminate other running copies of Agent Isle so only one owns the event port.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != me {
            app.forceTerminate()
        }
    }

    /// Every launch: if the user has Claude Code but our hooks aren't properly
    /// installed, offer to install them. There's no permanent opt-out — we ask on
    /// each launch until the hooks are in place, after which this stops firing on
    /// its own (see `HookInstaller.isInstalled`).
    private func maybePromptForHooks() {
        guard HookInstaller.hasClaudeCode(),
              !HookInstaller.isInstalled() else { return }

        let alert = NSAlert()
        alert.messageText = "Enable Claude Code approvals?"
        alert.informativeText = """
        Agent Isle already monitors your sessions. To also approve permission \
        requests right from the notch, it can add hooks to your Claude Code config \
        (~/.claude/settings.json). You can remove them anytime from the gear menu.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let ok = HookInstaller.install()
            let done = NSAlert()
            done.messageText = ok ? "Hooks installed" : "Couldn't install hooks"
            done.informativeText = ok
                ? "Restart any running Claude Code sessions for approvals to take effect."
                : "See Console for details. You can retry from the gear menu."
            done.runModal()
        }
        // Not Now — we'll ask again next launch.
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🏝️"
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let demoItem = NSMenuItem(title: "Demo Mode", action: #selector(toggleDemo), keyEquivalent: "d")
        demoItem.target = self
        demoItem.state = store.demoMode ? .on : .off
        menu.addItem(demoItem)

        let soundItem = NSMenuItem(title: "Sound Alerts", action: #selector(toggleSound), keyEquivalent: "s")
        soundItem.target = self
        soundItem.state = AppSettings.shared.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let portItem = NSMenuItem(title: "Listening on localhost:\(EventServer.port)", action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        menu.addItem(portItem)

        let installItem = NSMenuItem(title: "Copy Claude Code Hook Command", action: #selector(copyHookCommand), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let hookItem = NSMenuItem(title: "Install Claude Code Hooks", action: #selector(toggleHooks), keyEquivalent: "")
        hookItem.target = self
        menu.addItem(hookItem)
        hookMenuItem = hookItem

        menu.addItem(.separator())

        let checkUpdateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)

        let autoUpdateItem = NSMenuItem(title: "Automatically Install Updates", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdateItem.target = self
        menu.addItem(autoUpdateItem)
        autoUpdateMenuItem = autoUpdateItem

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Refresh state-dependent titles whenever the menu is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        hookMenuItem?.title = HookInstaller.isInstalled()
            ? "Remove Claude Code Hooks"
            : "Install Claude Code Hooks"
        hookMenuItem?.isHidden = !HookInstaller.hasClaudeCode()
        autoUpdateMenuItem?.state = Updater.shared.autoInstall ? .on : .off
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func toggleAutoUpdate(_ sender: NSMenuItem) {
        Updater.shared.autoInstall.toggle()
        sender.state = Updater.shared.autoInstall ? .on : .off
    }

    @objc private func toggleHooks() {
        if HookInstaller.isInstalled() {
            HookInstaller.uninstall()
            return
        }
        let ok = HookInstaller.install()
        let done = NSAlert()
        done.messageText = ok ? "Hooks installed" : "Couldn't install hooks"
        done.informativeText = ok
            ? "Restart any running Claude Code sessions for approvals to take effect."
            : "See Console for details."
        done.runModal()
    }

    @objc private func toggleDemo(_ sender: NSMenuItem) {
        if store.demoMode {
            store.stopDemo()
            sender.state = .off
        } else {
            store.startDemo()
            sender.state = .on
        }
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        AppSettings.shared.soundEnabled.toggle()   // persists + syncs SoundPlayer
        sender.state = AppSettings.shared.soundEnabled ? .on : .off
    }

    @objc private func copyHookCommand() {
        let cmd = "curl -s -X POST http://localhost:\(EventServer.port)/event " +
                  "-H 'Content-Type: application/json' -d @-"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
}
