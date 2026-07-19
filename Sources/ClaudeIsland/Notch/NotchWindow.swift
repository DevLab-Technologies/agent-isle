import AppKit
import SwiftUI

/// A borderless, always-on-top panel anchored over the notch that hosts the island UI.
///
/// The panel is sized generously so the expanded island has room; the SwiftUI content
/// draws itself centered under the notch and stays transparent everywhere else so
/// clicks pass through to whatever is behind it.
final class NotchWindow: NSPanel {
    private var geometry: NotchGeometry

    init(store: SessionStore) {
        self.geometry = NotchGeometry.current()

        let size = NotchWindow.panelSize(for: geometry)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false

        let root = IslandRootView(geometry: geometry)
            .environmentObject(store)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        reposition()
    }

    /// The panel spans the full screen width at top so the island can grow without clipping.
    private static func panelSize(for geo: NotchGeometry) -> NSSize {
        NSSize(width: geo.screenFrame.width, height: 420)
    }

    func reposition() {
        geometry = NotchGeometry.current()
        let size = NotchWindow.panelSize(for: geometry)
        let x = geometry.screenFrame.minX
        let y = geometry.screenFrame.maxY - size.height
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // Borderless panels can't become key by default; allow it so buttons work.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
