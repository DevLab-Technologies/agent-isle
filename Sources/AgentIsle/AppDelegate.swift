import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

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
    private var switcherHotKey: GlobalHotKey?
    private var switcherPanel: SwitcherPanel?
    private var fullscreenMonitor: FullscreenMonitor?
    private var memoryWatchdog: MemoryWatchdog?
    /// True while we've raised the activation policy to `.regular` for the Settings window,
    /// so we know to lower it back to `.accessory` once that window closes.
    private var regularForSettings = false

    /// The menu-bar session panel (menu-bar / both modes). Built lazily on first open.
    private var panelPopover: NSPopover?
    /// The full dropdown menu used as the status item's click menu in notch-only mode.
    private var fullMenu: NSMenu?
    /// Launch overrides for notch-window visibility, independent of the display mode:
    /// demo/marketing capture forces it on, settings-capture suppresses it.
    private var forceNotchWindow = false
    private var suppressNotchWindow = false
    /// Re-evaluates notch visibility when the visible-session set changes (for "Auto-hide
    /// When Empty"). Only re-applies on the empty ⇄ non-empty transition, not every update.
    private var sessionsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Single instance: replace any older copy so they don't fight over the event
        // server port (4711). A fresh launch wins.
        terminateOtherInstances()

        // Floating island over the notch. Suppressed in settings-capture mode so it
        // doesn't float over the settings window during a screenshot. Actual visibility is
        // decided by `applyDisplayMode()` once the launch overrides below are known.
        let settingsCapture = ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] == "1"
        suppressNotchWindow = settingsCapture
        let window = NotchWindow(store: store, settings: AppSettings.shared)
        notchWindow = window

        setupStatusItem()

        // OS notifications for attention events. Give the notifier the store so banner
        // Allow/Deny actions can route back to a decision, then ask for authorization once.
        Notifier.shared.store = store
        Notifier.shared.requestAuthorization()

        // Quiet scenes: mute sound + notifications during Focus / screen-lock / screen-
        // sharing while the island keeps updating. The observer only tracks scene state and
        // calls back into AppSettings, which folds it into the sound/notifier enabled gates.
        QuietScenes.shared.onChange = { AppSettings.shared.applyMuting() }
        QuietScenes.shared.start()

        // Settings window: opened from the gear menu; notch tuning rebuilds the island.
        NotificationCenter.default.addObserver(
            forName: .openAgentIsleSettings, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.openSettings() }
            }
        NotificationCenter.default.addObserver(
            forName: .agentIsleGeometryChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleGeometryRefresh() }
            }
        // Reconfigure surfaces whenever the display mode changes in Settings.
        NotificationCenter.default.addObserver(
            forName: .agentIsleDisplayModeChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyDisplayMode() }
            }
        // Re-evaluate notch visibility when the "Hide in Fullscreen" preference changes.
        NotificationCenter.default.addObserver(
            forName: .agentIsleFullscreenPreferenceChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyDisplayMode() }
            }
        // Re-evaluate notch visibility when a visibility-affecting preference (e.g. "Auto-hide
        // When Empty") changes, so it takes effect immediately.
        NotificationCenter.default.addObserver(
            forName: .agentIsleNotchVisibilityChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyDisplayMode() }
            }
        // Show/hide the notch as sessions come and go, for "Auto-hide When Empty". Only the
        // empty ⇄ non-empty transition matters, so collapse the stream to that boolean.
        // `$sessions` emits the new array (in willSet), so derive emptiness from it directly
        // rather than reading the store's still-stale `visibleSessions`.
        sessionsCancellable = store.$sessions
            .map { sessions in
                MainActor.assumeIsolated { sessions.allSatisfy { AppSettings.shared.isHidden($0) } }
            }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyDisplayMode() }
            }
        // Track fullscreen so the notch island hides while it's occluded (respecting the
        // display mode and the "Hide in Fullscreen" preference).
        let monitor = FullscreenMonitor()
        monitor.onChange = { [weak self] in self?.applyDisplayMode() }
        monitor.start()
        fullscreenMonitor = monitor

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
            // Demo/marketing capture always wants the notch island visible.
            forceNotchWindow = true
        } else {
            ideWatcher = IdeWatcher(store: store)
            ideWatcher?.start()
        }

        // Now that the launch overrides are known, show the surfaces for the current mode.
        applyDisplayMode()

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

        // Set up CLI approvals on launch (zero-config first run, gentle nudge after that;
        // skipped entirely if the user opted out).
        if ProcessInfo.processInfo.environment["AGENT_ISLE_DEMO"] != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runIntegrationSetup()
            }
        }

        // Check GitHub for a newer release and prompt / auto-install.
        Updater.shared.store = store
        Updater.shared.start()

        // Memory safety net (off by default): relaunch if the process's footprint stays
        // high across consecutive checks, but never while a session is mid-prompt.
        let watchdog = MemoryWatchdog()
        watchdog.start(store: store)
        memoryWatchdog = watchdog

        // Global session switcher. Skip in capture modes so it doesn't interfere.
        if !settingsCapture && !demoLaunch {
            registerSwitcherHotKey()
        }
    }

    // MARK: - Global session switcher

    // TODO: make the chord user-configurable (AppSettings) — fixed at ⌃⌥⌘Space for now.
    // ⌃⌥⌘Space is chosen to avoid common system chords: ⌘Space (Spotlight),
    // ⌃Space / ⌃⌥Space (input sources), ⌃⌘Space (Character Viewer), and ⌥⌘Space
    // (Finder search window).
    private func registerSwitcherHotKey() {
        switcherHotKey = GlobalHotKey(keyCode: UInt32(kVK_Space),
                                      modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.toggleSwitcher() }
        }
    }

    private func toggleSwitcher() {
        if switcherPanel != nil {
            closeSwitcher()
        } else {
            showSwitcher()
        }
    }

    private func showSwitcher() {
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onResignKey = { [weak self] in
            Task { @MainActor in self?.closeSwitcher() }
        }

        let root = SwitcherView(
            store: store,
            onSelect: { [weak self] session in
                self?.closeSwitcher()
                Jumper.jump(to: session)
            },
            onDismiss: { [weak self] in self?.closeSwitcher() })
            .environmentObject(store)
            .environmentObject(AppSettings.shared)

        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let origin = NSPoint(x: f.midX - size.width / 2,
                                 y: f.midY - size.height / 2 + f.height * 0.12)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        switcherPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeSwitcher() {
        guard let panel = switcherPanel else { return }
        switcherPanel = nil          // clear first so resignKey's callback is a no-op
        panel.onResignKey = nil
        panel.orderOut(nil)
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
            // Restore the accessory activation policy once Settings closes (see
            // `raiseActivationPolicyForSettings`).
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.settingsWindowWillClose() }
                }
            // In capture mode, anchor top-left so the center notch panel doesn't overlap.
            if ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] == "1", let scr = NSScreen.main {
                win.setFrameTopLeftPoint(NSPoint(x: scr.frame.minX + 40, y: scr.frame.maxY - 40))
                win.level = .floating   // stay above other apps for a clean screenshot
            }
            settingsWindow = win
        }
        // In capture mode the app stays an accessory (the screenshot wants no Dock icon
        // or app menu); otherwise raise to `.regular` so Settings behaves like a normal
        // window — ⌘Tab presence, an app menu, and Dock icon while it's open.
        if ProcessInfo.processInfo.environment["AGENT_ISLE_SETTINGS"] != "1" {
            raiseActivationPolicyForSettings()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Raise the app to `.regular` for the Settings window. Guarded so repeated opens don't
    /// flip the policy more than once.
    private func raiseActivationPolicyForSettings() {
        guard !regularForSettings else { return }
        regularForSettings = true
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Settings is closing: drop back to `.accessory` so the app disappears from ⌘Tab and
    /// the Dock again — unless another standard window is still open that needs the regular
    /// policy (guarding against yanking the Dock icon out from under a visible window).
    func applicationWillTerminate(_ notification: Notification) {
        // Persist any debounced API-key edits if the app quits with settings still open.
        AppSettings.shared.flushPendingKeyWrites()
    }

    private func settingsWindowWillClose() {
        // Persist any debounced API-key edits before the window goes away.
        AppSettings.shared.flushPendingKeyWrites()
        guard regularForSettings else { return }
        regularForSettings = false
        guard !hasOtherRegularWindow() else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Whether any standard (titled) window other than the Settings window is currently
    /// visible. The notch panel and switcher are borderless/non-activating and don't count.
    private func hasOtherRegularWindow() -> Bool {
        NSApp.windows.contains { win in
            win !== settingsWindow && win.isVisible && win.styleMask.contains(.titled)
        }
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

    /// A CLI whose hooks Agent Isle can install for notch approvals. Built from the
    /// `CLIIntegration` registry, so any hook-capable CLI added there appears here (and in
    /// the launch setup and gear menu) automatically.
    struct HookTool {
        let name: String
        let hasTool: () -> Bool
        let isInstalled: () -> Bool
        let install: () -> Bool
        let uninstall: () -> Bool
    }

    static let hookTools: [HookTool] = CLIIntegration.hookCapable.map { integration in
        HookTool(name: integration.displayName,
                 hasTool: integration.hasCLI,
                 isInstalled: { integration.hook?.isInstalled() ?? false },
                 install: { integration.hook?.install() ?? false },
                 uninstall: { integration.hook?.uninstall() ?? true })
    }

    /// Zero-config setup. On the very first launch we auto-install hooks for every detected
    /// hook-capable CLI (unless the user turned auto-setup off), then show a summary with an
    /// Undo and a "keep doing this" toggle. After that first pass we fall back to gently
    /// offering to finish any CLI whose hook still isn't in place, until it is.
    private func runIntegrationSetup() {
        guard AppSettings.shared.autoSetupIntegrations else { return }
        if AppSettings.shared.integrationSetupDone {
            maybePromptForHooks()
        } else {
            autoInstallIntegrations()
        }
    }

    /// First-run auto-install: configure everything detected, report what changed.
    private func autoInstallIntegrations() {
        AppSettings.shared.integrationSetupDone = true
        let pending = Self.hookTools.filter { $0.hasTool() && !$0.isInstalled() }
        guard !pending.isEmpty else { return }

        let installed = pending.filter { $0.install() }
        guard !installed.isEmpty else { return }
        let names = listNames(installed.map(\.name))

        let alert = NSAlert()
        alert.messageText = "Integrations ready"
        alert.informativeText = """
        Agent Isle set up notch approvals for \(names). Restart any running sessions for \
        them to take effect. You can manage or remove these anytime in Settings › \
        Integrations.
        """
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Undo")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Set up new integrations automatically"
        alert.suppressionButton?.state = .on

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .off {
            AppSettings.shared.autoSetupIntegrations = false
        }
        if response == .alertSecondButtonReturn {           // Undo
            installed.forEach { _ = $0.uninstall() }
        }
    }

    /// Subsequent launches: for each detected CLI whose hooks aren't properly installed,
    /// offer to install them in a single prompt. Stops firing on its own once the hooks are
    /// in place (see each installer's `isInstalled`).
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
            // In menu-bar / both modes the button click opens the session panel popover
            // (see `applyDisplayMode`). A right-click always shows a minimal safety menu.
            // In notch-only mode a full dropdown menu is assigned to `item.menu`, which
            // takes over the click and leaves this action unused.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        fullMenu = menu
        statusItem = item
        // `applyDisplayMode()` (called from `applicationDidFinishLaunching`) decides whether
        // this menu is assigned to the item (notch-only) or the popover click is used.
    }

    // MARK: - Display mode / menu-bar panel

    /// Show the surfaces the current display mode calls for: the notch window and/or the
    /// menu-bar status item behavior. Safe to call repeatedly (launch + on mode change).
    private func applyDisplayMode() {
        let mode = AppSettings.shared.displayMode

        // Notch/pill window visibility.
        if notchWindowShouldShow {
            notchWindow?.orderFrontRegardless()
        } else {
            notchWindow?.orderOut(nil)
        }

        // Status-item behavior. With a menu assigned, a click opens that menu and the
        // button action is ignored; with no menu, the click fires `statusItemClicked`.
        guard let item = statusItem else { return }
        if mode.showsMenuBar {
            item.menu = nil
        } else {
            if panelPopover?.isShown == true { panelPopover?.performClose(nil) }
            item.menu = fullMenu
        }
    }

    /// Whether the notch/pill window should currently be visible. Launch overrides win:
    /// demo/marketing capture forces it on, settings capture suppresses it. Otherwise the
    /// display mode decides, and — when enabled — a fullscreen frontmost window hides it
    /// (the notch is occluded there anyway).
    private var notchWindowShouldShow: Bool {
        if suppressNotchWindow { return false }
        if forceNotchWindow { return true }
        guard AppSettings.shared.displayMode.showsNotch else { return false }
        if AppSettings.shared.hideInFullscreen && FullscreenMonitor.isFrontmostWindowFullscreen() {
            return false
        }
        if AppSettings.shared.autoHideWhenEmpty && store.visibleSessions.isEmpty {
            return false
        }
        return true
    }

    /// Left-click opens the session panel; right-click shows the minimal safety menu.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMinimalMenu()
        } else {
            togglePanelPopover()
        }
    }

    /// A minimal right-click menu so Settings and Quit are always reachable even when the
    /// click opens the panel. Assigned transiently, then cleared so the click action stays.
    private func showMinimalMenu() {
        guard let item = statusItem, let button = item.button else { return }
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Agent Isle",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    /// Toggle the session-panel popover anchored under the status item. It hosts the same
    /// expanded island content (`MenuBarPanel` -> `ExpandedIsland`), sharing the live store.
    private func togglePanelPopover() {
        guard let button = statusItem?.button else { return }
        let popover = ensurePanelPopover()
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // Bring the accessory app forward so the panel's chat field can take keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func ensurePanelPopover() -> NSPopover {
        if let popover = panelPopover { return popover }
        let root = MenuBarPanel()
            .environmentObject(store)
            .environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]   // popover tracks SwiftUI size
        let popover = NSPopover()
        // Semitransient (not transient): a transient popover dismisses itself the moment
        // the in-panel gear opens its menu (the menu takes key focus), making those actions
        // unusable. Semitransient keeps the panel up while interacting with the app's own
        // menus/controls, and it still closes when the user clicks another app.
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = controller
        panelPopover = popover
        return popover
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
