import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    private var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var ideWatcher: IdeWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Single instance: replace any older copy so they don't fight over the event
        // server port (4711). A fresh launch wins.
        terminateOtherInstances()

        // Floating island over the notch.
        let window = NotchWindow(store: store)
        window.orderFrontRegardless()
        notchWindow = window

        setupStatusItem()

        // Start the local event server so real agents can push updates.
        EventServer.shared = EventServer(store: store)
        EventServer.shared?.start()

        // Discover real sessions (local Claude Code + Grok/Copilot). No demo data by
        // default — a fresh install should never show fake sessions. Demo is opt-in
        // from the gear menu.
        ideWatcher = IdeWatcher(store: store)
        ideWatcher?.start()

        // Reposition if the display configuration changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.notchWindow?.reposition() }
            }

        // Offer to set up Claude Code approvals on launch (unless already done / opted out).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.maybePromptForHooks()
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

    private let optOutKey = "hookPromptOptOut"

    /// Once per launch: if the user has Claude Code but no hooks and hasn't opted out,
    /// offer to install them.
    private func maybePromptForHooks() {
        guard HookInstaller.hasClaudeCode(),
              !HookInstaller.isInstalled(),
              !UserDefaults.standard.bool(forKey: optOutKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Enable Claude Code approvals?"
        alert.informativeText = """
        Agent Isle already monitors your sessions. To also approve permission \
        requests right from the notch, it can add hooks to your Claude Code config \
        (~/.claude/settings.json). You can remove them anytime from the gear menu.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let ok = HookInstaller.install()
            let done = NSAlert()
            done.messageText = ok ? "Hooks installed" : "Couldn't install hooks"
            done.informativeText = ok
                ? "Restart any running Claude Code sessions for approvals to take effect."
                : "See Console for details. You can retry from the gear menu."
            done.runModal()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: optOutKey)
        default:
            break   // Not Now — ask again next launch
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🏝️"
        let menu = NSMenu()

        let demoItem = NSMenuItem(title: "Demo Mode", action: #selector(toggleDemo), keyEquivalent: "d")
        demoItem.target = self
        demoItem.state = store.demoMode ? .on : .off
        menu.addItem(demoItem)

        let soundItem = NSMenuItem(title: "Sound Alerts", action: #selector(toggleSound), keyEquivalent: "s")
        soundItem.target = self
        soundItem.state = SoundPlayer.shared.enabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let portItem = NSMenuItem(title: "Listening on localhost:\(EventServer.port)", action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        menu.addItem(portItem)

        let installItem = NSMenuItem(title: "Copy Claude Code Hook Command", action: #selector(copyHookCommand), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
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
        SoundPlayer.shared.enabled.toggle()
        sender.state = SoundPlayer.shared.enabled ? .on : .off
    }

    @objc private func copyHookCommand() {
        let cmd = "curl -s -X POST http://localhost:\(EventServer.port)/event " +
                  "-H 'Content-Type: application/json' -d @-"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
}
