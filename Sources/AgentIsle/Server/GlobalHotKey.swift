import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys fire regardless of which app is frontmost and — unlike an
/// `NSEvent` global key monitor — need no Accessibility / Input-Monitoring permission,
/// which makes them the reliable choice for a background accessory app.
///
/// The instance owns its registration; drop the reference (or call `unregister()`) to
/// remove the hotkey.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let id: UInt32

    /// Live instances keyed by hotkey id, so the C event callback can route a press back
    /// to the right Swift object without capturing context in the function pointer.
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x41474C48  // 'AGLH'

    /// - Parameters:
    ///   - keyCode: a virtual key code (e.g. `kVK_Space`).
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    ///   - handler: invoked on the main run loop each time the chord is pressed.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            GlobalHotKey.instances[hkID.id]?.handler()
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        GlobalHotKey.instances[id] = self
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
        GlobalHotKey.instances[id] = nil
    }

    deinit { unregister() }
}
