import AppKit

/// Describes where the physical notch sits on the active screen, with a sensible
/// fallback for Macs (and external displays) that have no notch.
struct NotchGeometry {
    /// Full screen frame in global (bottom-left origin) coordinates.
    let screenFrame: NSRect
    /// Width of the physical notch (or a synthesized pill width when there is none).
    let notchWidth: CGFloat
    /// Height of the physical notch / menu-bar area at the top.
    let notchHeight: CGFloat
    /// True when the display actually has a hardware notch.
    let hasHardwareNotch: Bool

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.notchFrame != nil }) ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if let screen, let notch = screen.notchFrame {
            return NotchGeometry(screenFrame: frame,
                                 notchWidth: notch.width,
                                 notchHeight: notch.height,
                                 hasHardwareNotch: true)
        }
        // No notch: synthesize a pill roughly the size of a real Dynamic Island notch.
        return NotchGeometry(screenFrame: frame,
                             notchWidth: 220,
                             notchHeight: 32,
                             hasHardwareNotch: false)
    }
}

extension NSScreen {
    /// The notch rectangle in this screen's coordinate space, if the display has one.
    var notchFrame: NSRect? {
        guard safeAreaInsets.top > 0 else { return nil }
        // The auxiliary top areas flank the notch; the gap between them is the notch.
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else {
            // Fallback: estimate a centered notch when auxiliary areas aren't exposed.
            let width: CGFloat = 200
            let height = safeAreaInsets.top
            let x = frame.midX - width / 2
            let y = frame.maxY - height
            return NSRect(x: x, y: y, width: width, height: height)
        }
        let notchX = left.maxX
        let notchWidth = right.minX - left.maxX
        let height = safeAreaInsets.top
        return NSRect(x: notchX, y: frame.maxY - height, width: notchWidth, height: height)
    }
}
