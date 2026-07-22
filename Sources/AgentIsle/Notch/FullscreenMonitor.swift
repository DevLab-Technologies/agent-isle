import AppKit

/// Watches for the frontmost window entering or leaving fullscreen so the app can hide the
/// notch island while it's occluded (a fullscreen app covers the notch/menu-bar strip).
///
/// macOS exposes no direct "is this other app fullscreen?" query to an accessory app, so we
/// infer it: a fullscreen window lives on its own Space and covers the entire display —
/// including the menu-bar/notch area — whereas a merely zoomed window stops below the menu
/// bar. We compare the frontmost app's on-screen windows against the notch display's full
/// bounds. Space switches and app activations are the moments this can change, so we
/// re-evaluate on both.
@MainActor
final class FullscreenMonitor {
    /// Invoked (on the main queue) whenever the fullscreen state may have changed. The
    /// receiver should read `Self.isFrontmostWindowFullscreen()` and update visibility.
    var onChange: () -> Void = {}

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        // Entering/leaving fullscreen switches Spaces; switching apps can also bring a
        // fullscreen (or windowed) app to the front. Both change what occludes the notch.
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
            observers.append(token)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
    }

    /// Best-effort detection of a fullscreen frontmost window on the notch display.
    ///
    /// Returns true when the frontmost application owns a normal-level window whose bounds
    /// cover the whole notch display. A zoomed/maximized window sits below the menu bar and
    /// so fails the top-edge test; a genuine fullscreen window reaches y == 0 and spans the
    /// full height, which is what occludes the notch.
    static func isFrontmostWindowFullscreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        guard let displayBounds = notchDisplayBounds() else { return false }

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if windowCoversDisplay(bounds, display: displayBounds) { return true }
        }
        return false
    }

    /// CG (top-left origin) bounds of the display that hosts the notch island — the same
    /// screen `NotchGeometry` targets. Falls back to the main display.
    private static func notchDisplayBounds() -> CGRect? {
        let screen = NSScreen.screens.first(where: { $0.notchFrame != nil }) ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    /// Whether `window` covers effectively all of `display`. A small tolerance absorbs
    /// sub-pixel/backing-scale rounding in the reported window bounds.
    private static func windowCoversDisplay(_ window: CGRect, display: CGRect, tolerance: CGFloat = 2) -> Bool {
        window.minX <= display.minX + tolerance &&
        window.minY <= display.minY + tolerance &&
        window.maxX >= display.maxX - tolerance &&
        window.maxY >= display.maxY - tolerance
    }
}
