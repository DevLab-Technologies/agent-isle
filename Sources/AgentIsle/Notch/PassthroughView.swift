import AppKit

/// Content view that only claims mouse events inside `interactiveRect`; clicks
/// anywhere else fall through to whatever window is behind (menu bar, other apps).
///
/// This is what stops the island's window from hijacking the whole top of the screen.
final class PassthroughView: NSView {
    /// The clickable region, in this view's (bottom-left origin) coordinates.
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
