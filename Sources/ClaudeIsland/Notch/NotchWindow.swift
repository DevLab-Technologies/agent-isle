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

    private let sideMargin: CGFloat = 40   // room for the expanded panel's shadow
    private let bottomMargin: CGFloat = 48

    init(store: SessionStore) {
        self.geometry = NotchGeometry.current()
        self.store = store

        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
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

        let container = PassthroughView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let root = IslandRootView(geometry: geometry).environmentObject(store)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container

        applySize(store.islandSize)

        // Resize/reposition whenever SwiftUI reports a new island size.
        cancellable = store.$islandSize
            .removeDuplicates { abs($0.width - $1.width) < 0.5 && abs($0.height - $1.height) < 0.5 }
            .sink { [weak self] size in self?.applySize(size) }
    }

    /// Size the window to the island (plus shadow margins) and anchor it top-center,
    /// then update the passthrough hit region to the island's exact rect.
    private func applySize(_ islandSize: CGSize) {
        geometry = NotchGeometry.current()
        let screen = geometry.screenFrame

        let winW = islandSize.width + sideMargin * 2
        let winH = islandSize.height + bottomMargin
        let x = screen.midX - winW / 2
        let y = screen.maxY - winH   // top edge flush with the screen top / notch
        setFrame(NSRect(x: x, y: y, width: winW, height: winH), display: true)

        // Island sits at the top-center of the window; compute its rect (bottom-left origin).
        let rect = NSRect(x: sideMargin,
                          y: winH - islandSize.height,
                          width: islandSize.width,
                          height: islandSize.height)
        (contentView as? PassthroughView)?.interactiveRect = rect
    }

    func reposition() {
        applySize(store.islandSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
