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
    private var cancellable: AnyCancellable?

    // The window is a FIXED size large enough for the expanded island and never
    // resizes — resizing on hover caused mouse-tracking flicker near the notch.
    // Click-through is handled entirely by the PassthroughView's hit region instead.
    private let fixedWidth: CGFloat = 640
    private let fixedHeight: CGFloat = 500
    private let hitPadding: CGFloat = 10   // enlarge the hit region slightly to steady hover

    init(store: SessionStore) {
        self.geometry = NotchGeometry.current()
        self.store = store

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

        let container = PassthroughView(frame: NSRect(x: 0, y: 0, width: fixedWidth, height: fixedHeight))
        let root = IslandRootView(geometry: geometry).environmentObject(store)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container

        positionWindow()
        updateHitRegion(store.islandSize)

        // Only the hit region tracks the island size; the window itself stays put.
        cancellable = store.$islandSize
            .removeDuplicates { abs($0.width - $1.width) < 0.5 && abs($0.height - $1.height) < 0.5 }
            .sink { [weak self] size in self?.updateHitRegion(size) }
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
    }

    func reposition() {
        positionWindow()
        updateHitRegion(store.islandSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
