import SwiftUI
import ServiceManagement

/// Defaults keys shared beyond `AppSettings` — e.g. `NotchGeometry` reads the notch
/// offsets directly (to stay actor-free), so the key strings must live in one place.
enum DefaultsKeys {
    static let notchWidthAdjust = "notchWidthAdjust"
    static let notchHeightAdjust = "notchHeightAdjust"
}

/// User preferences, persisted to `UserDefaults` and observed by the views and the
/// runtime pieces that react to them (sound, notch geometry, hover-expand, card layout).
///
/// One shared instance drives both the settings window and the live island, so a change
/// in preferences takes effect immediately everywhere it's read.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // MARK: Sound
    @Published var soundEnabled: Bool {
        didSet { d.set(soundEnabled, forKey: Key.soundEnabled); SoundPlayer.shared.enabled = soundEnabled }
    }
    /// 0…1; scales the synthesized chiptune amplitude (see `SoundPlayer`).
    @Published var soundVolume: Double {
        didSet { d.set(soundVolume, forKey: Key.soundVolume); SoundPlayer.shared.volume = soundVolume }
    }

    // MARK: Notifications
    @Published var notificationsEnabled: Bool {
        didSet { d.set(notificationsEnabled, forKey: Key.notificationsEnabled); Notifier.shared.enabled = notificationsEnabled }
    }

    // MARK: Behavior
    @Published var expandOnHover: Bool { didSet { d.set(expandOnHover, forKey: Key.expandOnHover) } }

    // MARK: Session card
    @Published var showTokens: Bool { didSet { d.set(showTokens, forKey: Key.showTokens) } }
    @Published var showTerminal: Bool { didSet { d.set(showTerminal, forKey: Key.showTerminal) } }
    @Published var showTasks: Bool { didSet { d.set(showTasks, forKey: Key.showTasks) } }
    @Published var showModel: Bool { didSet { d.set(showModel, forKey: Key.showModel) } }
    @Published var showSubAgents: Bool { didSet { d.set(showSubAgents, forKey: Key.showSubAgents) } }

    // MARK: Display / notch tuning
    /// Manual offsets (pts) added to the OS-reported notch size; 0 uses the API value.
    @Published var notchWidthAdjust: Double {
        didSet { d.set(notchWidthAdjust, forKey: Key.notchWidthAdjust); postGeometryChange() }
    }
    @Published var notchHeightAdjust: Double {
        didSet { d.set(notchHeightAdjust, forKey: Key.notchHeightAdjust); postGeometryChange() }
    }
    @Published var maxPanelWidth: Double { didSet { d.set(maxPanelWidth, forKey: Key.maxPanelWidth) } }
    @Published var maxPanelHeight: Double { didSet { d.set(maxPanelHeight, forKey: Key.maxPanelHeight) } }

    private enum Key {
        static let soundEnabled = "soundEnabled"
        static let soundVolume = "soundVolume"
        static let notificationsEnabled = "notificationsEnabled"
        static let expandOnHover = "expandOnHover"
        static let showTokens = "showTokens"
        static let showTerminal = "showTerminal"
        static let showTasks = "showTasks"
        static let showModel = "showModel"
        static let showSubAgents = "showSubAgents"
        static let notchWidthAdjust = DefaultsKeys.notchWidthAdjust
        static let notchHeightAdjust = DefaultsKeys.notchHeightAdjust
        static let maxPanelWidth = "maxPanelWidth"
        static let maxPanelHeight = "maxPanelHeight"
    }

    private init() {
        d.register(defaults: [
            Key.soundEnabled: true,
            Key.soundVolume: 0.6,
            Key.notificationsEnabled: true,
            Key.expandOnHover: true,
            Key.showTokens: true,
            Key.showTerminal: true,
            Key.showTasks: true,
            Key.showModel: true,
            Key.showSubAgents: true,
            Key.notchWidthAdjust: 0,
            Key.notchHeightAdjust: 0,
            Key.maxPanelWidth: 480,
            Key.maxPanelHeight: 380,
        ])
        soundEnabled = d.bool(forKey: Key.soundEnabled)
        soundVolume = d.double(forKey: Key.soundVolume)
        notificationsEnabled = d.bool(forKey: Key.notificationsEnabled)
        expandOnHover = d.bool(forKey: Key.expandOnHover)
        showTokens = d.bool(forKey: Key.showTokens)
        showTerminal = d.bool(forKey: Key.showTerminal)
        showTasks = d.bool(forKey: Key.showTasks)
        showModel = d.bool(forKey: Key.showModel)
        showSubAgents = d.bool(forKey: Key.showSubAgents)
        notchWidthAdjust = d.double(forKey: Key.notchWidthAdjust)
        notchHeightAdjust = d.double(forKey: Key.notchHeightAdjust)
        maxPanelWidth = d.double(forKey: Key.maxPanelWidth)
        maxPanelHeight = d.double(forKey: Key.maxPanelHeight)

        // Push initial sound prefs into the player (didSet doesn't fire during init).
        SoundPlayer.shared.enabled = soundEnabled
        SoundPlayer.shared.volume = soundVolume
        // Same for the notifier's enabled flag.
        Notifier.shared.enabled = notificationsEnabled
    }

    private func postGeometryChange() {
        NotificationCenter.default.post(name: .agentIsleGeometryChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted when the user changes notch tuning; the window rebuilds its geometry.
    static let agentIsleGeometryChanged = Notification.Name("AgentIsleGeometryChanged")
    /// Posted from the island's gear menu to open the settings window.
    static let openAgentIsleSettings = Notification.Name("OpenAgentIsleSettings")
}

/// Thin wrapper over `SMAppService` for the "Launch at Login" toggle. In a packaged
/// `.app` this registers a login item; from a bare debug binary it has no bundle to
/// register and simply reports/records failure without crashing.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns true on success. A thrown error (e.g. unsigned/unbundled dev build) is
    /// reported to the caller so the UI can revert the toggle.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
            return false
        }
    }
}
