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
    private var cursorHookMenuItem: NSMenuItem?
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

        // OS notifications for attention events. Give the notifier the store so banner
        // Allow/Deny actions can route back to a decision, then ask for authorization once.
        Notifier.shared.store = store
        Notifier.shared.requestAuthorization()

        // Settings window: opened from the gear menu; notch tuning rebuilds the island.
        NotificationCenter.default.addObserver(
            forName: .openAgentIsleSettings, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.openSettings() }
            }
        NotificationCenter.default.addObserver(
            forName: .agentIsleGeometryChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleGeometryRefresh() }
            }

        // Discover real sessions (local Claude Code + Grok/Copilot). No demo data by
        // default — a fresh install should never show fake sessions. Demo is opt-in
        // from the gear menu.
        // Dev/marketing: `AGENT_ISLE_DEMO=1` opens the island expanded with demo data so
        // the panel can be captured without wiring up a real agent. In this mode we skip
        // the event server and live watcher (which would otherwise replace the demo with
        // real sessions) and the hook prompt.
        let demoLaunch = ProcessInfo.processInfo.environment["AGENT_ISLE_DEMO"] == "1"

        // Start the local event server so real agents can push updates.
        if !demoLaunch {
            EventServer.shared = EventServer(store: store)
            EventServer.shared?.start()
        }

        if demoLaunch {
            store.startDemo()
            store.isExpanded = true
            // Sit above any other notch app (e.g. an installed build) for a clean capture.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
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

    /// A CLI whose hooks Agent Isle can install for notch approvals. Claude Code and
    /// Cursor share the same shape (detect / installed? / install / remove), so the
    /// launch prompt and gear menu drive both through this descriptor.
    struct HookTool {
        let name: String
        let hasTool: () -> Bool
        let isInstalled: () -> Bool
        let install: () -> Bool
        let uninstall: () -> Bool
    }

    static let hookTools: [HookTool] = [
        HookTool(name: "Claude Code",
                 hasTool: HookInstaller.hasClaudeCode, isInstalled: HookInstaller.isInstalled,
                 install: HookInstaller.install, uninstall: HookInstaller.uninstall),
        HookTool(name: "Cursor",
                 hasTool: CursorHookInstaller.hasCursor, isInstalled: CursorHookInstaller.isInstalled,
                 install: CursorHookInstaller.install, uninstall: CursorHookInstaller.uninstall),
    ]

    /// Every launch: for each detected CLI whose hooks aren't properly installed, offer to
    /// install them in a single prompt. There's no permanent opt-out — we ask on each
    /// launch until the hooks are in place, after which this stops firing on its own (see
    /// each installer's `isInstalled`).
    private func maybePromptForHooks() {
        let pending = Self.hookTools.filter { $0.hasTool() && !$0.isInstalled() }
        guard !pending.isEmpty else { return }
        let names = listNames(pending.map(\.name))

        let alert = NSAlert()
        alert.messageText = "Enable \(names) approvals?"
        alert.informativeText = """
        Agent Isle already monitors your sessions. To also approve permission \
        requests right from the notch, it can add hooks to your \(names) config. \
        You can remove them anytime from the gear menu.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let ok = pending.map { $0.install() }.allSatisfy { $0 }
            let done = NSAlert()
            done.messageText = ok ? "Hooks installed" : "Couldn't install some hooks"
            done.informativeText = ok
                ? "Restart any running \(names) sessions for approvals to take effect."
                : "See Console for details. You can retry from the gear menu."
            done.runModal()
        }
        // Not Now — we'll ask again next launch.
    }

    /// "Claude Code", "Claude Code and Cursor", "A, B and C".
    private func listNames(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return names[0]
        case 2:  return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        // A template SF Symbol renders reliably in the menu bar (adapting to light/dark
        // and the bar's tint); an emoji set via `title` can come out zero-width and look
        // like "no icon". Fall back to the emoji only if the symbol is unavailable.
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: "Agent Isle") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🏝️"
            }
            button.toolTip = "Agent Isle"
        }
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

        let cursorHookItem = NSMenuItem(title: "Install Cursor Hooks", action: #selector(toggleCursorHooks), keyEquivalent: "")
        cursorHookItem.target = self
        menu.addItem(cursorHookItem)
        cursorHookMenuItem = cursorHookItem

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
        cursorHookMenuItem?.title = CursorHookInstaller.isInstalled()
            ? "Remove Cursor Hooks"
            : "Install Cursor Hooks"
        cursorHookMenuItem?.isHidden = !CursorHookInstaller.hasCursor()
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
        toggle(Self.hookTools[0])
    }

    @objc private func toggleCursorHooks() {
        toggle(Self.hookTools[1])
    }

    private func toggle(_ tool: HookTool) {
        if tool.isInstalled() {
            _ = tool.uninstall()
            return
        }
        let ok = tool.install()
        let done = NSAlert()
        done.messageText = ok ? "Hooks installed" : "Couldn't install hooks"
        done.informativeText = ok
            ? "Restart any running \(tool.name) sessions for approvals to take effect."
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
