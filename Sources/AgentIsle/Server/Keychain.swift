import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for the handful of secrets Agent Isle stores —
/// the user's own (opt-in) TTS / summary API keys for the "bring your own key" voice
/// providers. Keys never touch `UserDefaults`: they live as generic-password items so they
/// stay out of plists, backups-in-the-clear, and diagnostic exports.
///
/// All items share one service; the `account` distinguishes them (one per provider). Every
/// call is best-effort — a Keychain failure returns nil / false rather than throwing, since
/// a missing key simply means that provider falls back to the local engine.
enum Keychain {
    private static let service = "com.devlab.agent-isle"

    /// Store (or, with `nil`/empty, delete) a secret for `account`. Returns true on success.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return delete(account) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            // Available after first unlock, this-device-only: usable by the background app
            // without prompting, and never synced to iCloud or migrated to another Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Update in place if it already exists; otherwise add. This avoids duplicate-item
        // errors and needless delete/add churn.
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Fetch the secret for `account`, or nil if absent / unreadable.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Stable account names for the secrets Agent Isle stores.
    enum Account {
        static let openAIKey = "voice.openai.key"
        static let elevenLabsKey = "voice.elevenlabs.key"
        static let anthropicKey = "voice.anthropic.key"
    }
}
