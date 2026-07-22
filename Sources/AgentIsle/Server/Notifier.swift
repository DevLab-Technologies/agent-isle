import Foundation
import UserNotifications
import AppKit

/// Delivers macOS banner notifications for attention events, alongside the chiptune cues
/// from `SoundPlayer`. Permission banners carry Allow / Deny actions so a decision can be
/// made straight from the banner, routed back through the same `SessionStore` path the
/// in-panel card uses.
///
/// Main-actor isolated: `enabled` is driven from `AppSettings` and the fire methods are
/// called from the (main-actor) event server, store, and watcher.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    /// Driven by `AppSettings.notificationsEnabled`; gates every notification.
    var enabled = true

    /// The session store, used to route banner Allow/Deny actions back to a decision and to
    /// suppress a banner when its panel is already expanded and frontmost. Weak so the
    /// notifier never keeps the store alive.
    weak var store: SessionStore?

    private let center = UNUserNotificationCenter.current()

    /// Category + action identifiers for the permission banner.
    private enum ID {
        static let permissionCategory = "agentisle.permission"
        static let allowAction = "agentisle.allow"
        static let denyAction = "agentisle.deny"
    }

    /// userInfo keys carried on every notification.
    private enum Key {
        static let session = "sessionID"
    }

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    /// Register the permission category so its banner shows Allow / Deny buttons.
    private func registerCategories() {
        let allow = UNNotificationAction(identifier: ID.allowAction, title: "Allow",
                                         options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: ID.denyAction, title: "Deny",
                                        options: [.destructive])
        let permission = UNNotificationCategory(identifier: ID.permissionCategory,
                                                actions: [allow, deny],
                                                intentIdentifiers: [],
                                                options: [])
        center.setNotificationCategories([permission])
    }

    /// Ask the user once for permission to post notifications. Safe to call on every launch;
    /// the system only prompts the first time.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error { NSLog("Notifier: authorization failed: \(error.localizedDescription)") }
            else if !granted { NSLog("Notifier: notifications not authorized") }
        }
    }

    // MARK: - Firing

    func notifyPermission(session: AgentSession, tool: String, command: String?) {
        let detail = command ?? session.permission?.filePath ?? tool
        deliver(session: session,
                title: "\(session.agent.displayName) needs permission",
                body: "\(tool): \(detail)",
                category: ID.permissionCategory)
    }

    func notifyQuestion(session: AgentSession, summary: String) {
        deliver(session: session,
                title: "\(session.agent.displayName) has a question",
                body: summary,
                category: nil)
    }

    func notifyPlan(session: AgentSession, summary: String) {
        deliver(session: session,
                title: "\(session.agent.displayName) shared a plan",
                body: summary,
                category: nil)
    }

    func notifyDone(session: AgentSession, title: String) {
        deliver(session: session,
                title: "\(session.agent.displayName) finished",
                body: title,
                category: nil)
    }

    /// Build and post a notification, honoring the enabled toggle and the
    /// already-visible-panel suppression. `category` attaches Allow/Deny actions.
    private func deliver(session: AgentSession, title: String, body: String, category: String?) {
        guard enabled, !isPanelFrontmost else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No notification sound: SoundPlayer already plays a cue at the same moment.
        content.userInfo = [Key.session: session.id.uuidString]
        if let category { content.categoryIdentifier = category }

        // The session's stable UUID is the identifier, so a newer banner for the same
        // session replaces an older one rather than stacking.
        let request = UNNotificationRequest(identifier: session.id.uuidString,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("Notifier: could not post notification: \(error.localizedDescription)") }
        }
    }

    /// Suppress a banner when the island panel is already expanded and the app is frontmost —
    /// the user is looking at the card, so a banner would just double up.
    private var isPanelFrontmost: Bool {
        (store?.isExpanded ?? false) && NSApp.isActive
    }
}

// MARK: - Delegate

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is frontmost (the suppression above already skips
    /// the case where the panel is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// Route a banner Allow / Deny tap back through the store, exactly like the in-panel card.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let idString = userInfo["sessionID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let idString, let sessionID = UUID(uuidString: idString),
                  let store = self.store else { return }
            switch action {
            case ID.allowAction:
                store.resolvePermission(sessionID: sessionID, decision: .allowOnce)
            case ID.denyAction:
                store.resolvePermission(sessionID: sessionID, decision: .deny)
            default:
                // A plain tap on the banner: surface the panel so the user can act.
                store.isExpanded = true
            }
        }
    }
}
