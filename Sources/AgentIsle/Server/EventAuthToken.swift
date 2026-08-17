import Darwin
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

    /// Create `url` if needed and force it to `0700`. `createDirectory(attributes:)` only
    /// applies the mode when it actually creates the directory — `~/.agent-isle` already
    /// exists at `0755` for anyone who installed hooks.
    nonisolated static func ensurePrivateDirectory(_ url: URL = directoryURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Persist `token` owner-only. `directory` is overridable so tests never touch the
    /// real `~/.agent-isle/token`. The temp file is created `0600` via `open(O_EXCL)` —
    /// `Data.write(.atomic)` only gives atomic replacement, not a restrictive mode.
    nonisolated static func write(_ token: String, directory: URL = directoryURL) throws {
        try ensurePrivateDirectory(directory)
        let fm = FileManager.default
        let dest = directory.appendingPathComponent("token", isDirectory: false)
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)

        let fd = tmp.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        let bytes = Array(token.utf8)
        let written = bytes.withUnsafeBytes { buf in
            Darwin.write(fd, buf.baseAddress, buf.count)
        }
        close(fd)
        guard written == bytes.count else {
            try? fm.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tmp, to: dest)
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
