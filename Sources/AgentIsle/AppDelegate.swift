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

        // Floating island over the notch.
        let window = NotchWindow(store: store)
        window.orderFrontRegardless()
        notchWindow = window

        setupStatusItem()

        // Start the local event server so real agents can push updates.
        EventServer.shared = EventServer(store: store)
        EventServer.shared?.start()

        // Fill the island with demo data until real sessions arrive.
        store.startDemo()

        // Discover running IDE (VS Code / Cursor) Claude Code sessions — no hooks needed.
        // Its first scan replaces the demo data if real sessions are found.
        ideWatcher = IdeWatcher(store: store)
        ideWatcher?.start()

        // Reposition if the display configuration changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.notchWindow?.reposition() }
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
