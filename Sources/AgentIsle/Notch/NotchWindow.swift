import AppKit
import SwiftUI
import Combine

/// A borderless, always-on-top panel anchored over the notch that hosts the island UI.
///
/// The window resizes to fit the island (reported by SwiftUI via `store.islandSize`) so
/// it only ever covers a small region, and a `PassthroughView` makes even that region
/// click-through outside the island's actual bounds. Together these ensure the app never
/// blocks the menu bar or other windows.
final class NotchWindow: NSPanel {
    private var geometry: NotchGeometry
    private let store: SessionStore
    private let settings: AppSettings
    private var hosting: NSHostingView<AnyView>?
    private var cancellable: AnyCancellable?
    private var keyCancellable: AnyCancellable?
    private var hoverCancellable: AnyCancellable?
    private var mouseMonitors: [Any] = []
    /// Polls the pointer while hovering; catches exits through the window's dead zone
    /// (see `startHoverPolling`).
    private var hoverPoll: Timer?

    // The window is a FIXED size large enough for the expanded island and never
    // resizes — resizing on hover caused mouse-tracking flicker near the notch.
    // Click-through is handled entirely by the PassthroughView's hit region instead.
    private let fixedWidth: CGFloat = 640
    private let fixedHeight: CGFloat = 500
    private let hitPadding: CGFloat = 10   // enlarge the hit region slightly to steady hover

    init(store: SessionStore, settings: AppSettings) {
        self.geometry = NotchGeometry.current()
        self.store = store
        self.settings = settings

        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        let container = PassthroughView(frame: NSRect(x: 0, y: 0, width: fixedWidth, height: fixedHeight))
        let hostingView = NSHostingView(rootView: makeRoot())
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
        self.hosting = hostingView

        positionWindow()
        updateHitRegion(store.islandSize)

        // Only the hit region tracks the island size; the window itself stays put.
        cancellable = store.$islandSize
            .removeDuplicates { abs($0.width - $1.width) < 0.5 && abs($0.height - $1.height) < 0.5 }
            .sink { [weak self] size in self?.updateHitRegion(size) }

        // Take key focus while the panel is explicitly expanded (clicked open) or a chat
        // is open, so in-panel keyboard shortcuts and the chat text field receive input.
        // Key-ness is deliberately gated to the *explicit* expanded state — not hover —
        // so merely passing the pointer over the notch never steals keystrokes from the
        // frontmost terminal. On collapse we best-effort resign key: the app is a
        // non-activating accessory, so the terminal keeps receiving keystrokes regardless;
        // this just avoids the panel holding key status once it's no longer interactive.
        keyCancellable = Publishers.CombineLatest(store.$isExpanded, store.$openedSessionID)
            .map { isExpanded, opened in isExpanded || opened != nil }
            .removeDuplicates()
            .sink { [weak self] shouldBeKey in
                guard let self else { return }
                if shouldBeKey {
                    self.makeKeyAndOrderFront(nil)
                } else if self.isKeyWindow {
                    self.resignKey()
                }
            }

        startPointerMonitoring()

        // Poll the pointer only while hovering, to catch the exit. The move monitors
        // above don't fire in the window's "dead zone" — the fixed panel is far larger
        // than the island, and `PassthroughView.hitTest` returns nil off the island, so
        // the pointer sitting there (off the island but inside the window) sends us no
        // mouse-moved events and the global monitor doesn't fire either. Without this the
        // island stays expanded until the pointer leaves the whole fixed window.
        hoverCancellable = store.$isHovering
            .removeDuplicates()
            .sink { [weak self] hovering in self?.startHoverPolling(hovering) }
    }

    deinit {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        hoverPoll?.invalidate()
    }

    /// Drive the island's hover state from the real pointer location instead of
    /// SwiftUI's `.onHover`, whose mouse-exit event is unreliable at the top screen
    /// edge and would occasionally leave the island stuck open. A global monitor
    /// catches movement over other apps; a local one catches movement over our panel.
    private func startPointerMonitoring() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in self?.syncHoverToPointer()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in self?.syncHoverToPointer(); return event
        }
        mouseMonitors = [global, local].compactMap { $0 }
        syncHoverToPointer()
    }

    /// Start/stop a lightweight pointer poll for the duration of a hover. The poll runs
    /// only while `isHovering` is true, so there's no cost when the island is idle; it
    /// stops as soon as the collapse it triggers lands.
    private func startHoverPolling(_ hovering: Bool) {
        hoverPoll?.invalidate()
        hoverPoll = nil
        guard hovering else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.syncHoverToPointer()
        }
        // .common so it keeps firing during scrolls/tracking runloop modes.
        RunLoop.main.add(timer, forMode: .common)
        hoverPoll = timer
    }

    private func syncHoverToPointer() {
        guard let view = contentView as? PassthroughView else { return }
        // `interactiveRect` is in the borderless window's base coordinates, so it
        // converts straight to screen space for comparison with the cursor.
        let screenRect = convertToScreen(view.interactiveRect)
        let inside = screenRect.contains(NSEvent.mouseLocation)
        MainActor.assumeIsolated { store.setHovering(inside) }
    }

    private func positionWindow() {
        geometry = NotchGeometry.current()
        let screen = geometry.screenFrame
        let x = screen.midX - fixedWidth / 2
        let y = screen.maxY - fixedHeight   // top edge flush with the screen top / notch
        setFrame(NSRect(x: x, y: y, width: fixedWidth, height: fixedHeight), display: true)
    }

    /// The island renders at the top-center of the fixed window; mark exactly that
    /// rect (plus a little padding) as clickable so everything else stays click-through.
    private func updateHitRegion(_ islandSize: CGSize) {
        let w = islandSize.width + hitPadding * 2
        let h = islandSize.height + hitPadding * 2
        let x = (fixedWidth - w) / 2
        let y = fixedHeight - h   // top-aligned
        (contentView as? PassthroughView)?.interactiveRect = NSRect(x: x, y: y, width: w, height: h)
        // The rect just changed, so a stationary pointer may now be outside it even
        // though no mouse-move fired. Re-evaluate hover against the new rect, otherwise
        // the panel stays expanded after it shrinks (e.g. a question card clears)
        // until the pointer next moves.
        syncHoverToPointer()
    }

    /// Builds the island root with its environment objects. Type-erased so the hosting
    /// view has a stable type across geometry rebuilds.
    private func makeRoot() -> AnyView {
        AnyView(IslandRootView(geometry: geometry)
            .environmentObject(store)
            .environmentObject(settings))
    }

    func reposition() {
        positionWindow()
        updateHitRegion(store.islandSize)
    }

    /// Recompute notch geometry (after the user tunes it) and rebuild the island.
    func refreshGeometry() {
        geometry = NotchGeometry.current()
        hosting?.rootView = makeRoot()
        positionWindow()
        updateHitRegion(store.islandSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
