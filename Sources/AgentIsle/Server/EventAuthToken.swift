import Foundation
import Security

/// Per-machine shared secret that authenticates local hooks against `EventServer`.
///
/// Stored at `~/.agent-isle/token` (directory `0700`, file `0600`) so only the current user
/// can read it. The app creates the token on first launch; Python hooks send it as
/// `X-Agent-Isle-Token`. Loopback binding already blocks the LAN — this stops *other local
/// processes* from injecting sessions or stealing parked permission connections.
enum EventAuthToken {
    /// Header hooks must send (case-insensitive on the wire).
    nonisolated static let headerName = "X-Agent-Isle-Token"

    /// Directory under the user's home that holds the token (and debug logs).
    nonisolated static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-isle", isDirectory: true)
    }

    nonisolated static var tokenFileURL: URL {
        directoryURL.appendingPathComponent("token", isDirectory: false)
    }

    /// Load the existing token, or create one if missing. Best-effort: on total failure
    /// returns a process-local random token so the server still rejects strangers (hooks
    /// simply won't match until the file becomes writable).
    nonisolated static func loadOrCreate() -> String {
        if let existing = read() { return existing }
        let token = randomToken()
        do {
            try write(token)
            return token
        } catch {
            NSLog("EventAuthToken: could not persist token: \(error)")
            return token
        }
    }

    /// Read the on-disk token, or nil if absent / unreadable.
    nonisolated static func read() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let string = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Constant-time string compare so a local attacker cannot trivially time the token.
    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    // MARK: - Internals

    nonisolated private static func write(_ token: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        // Atomic create with owner-only mode so a concurrent reader never sees a partial file
        // with looser permissions.
        let data = Data(token.utf8)
        let tmp = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // replaceItemAt is not available on all SDKs the same way — remove + move is fine
        // under the private directory.
        if fm.fileExists(atPath: tokenFileURL.path) {
            try fm.removeItem(at: tokenFileURL)
        }
        try fm.moveItem(at: tmp, to: tokenFileURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
    }

    nonisolated private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Fallback: UUID entropy if the CSPRNG is unavailable (should never happen).
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
