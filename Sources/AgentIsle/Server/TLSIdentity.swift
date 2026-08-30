import Foundation
import Security
import Network

/// Turns a PEM certificate + private key into a `sec_identity_t` Network.framework can
/// serve TLS with. macOS has no public API for building a `SecIdentity` from bare cert+key
/// data directly, so this goes through the one supported path: package them as PKCS#12
/// (via `openssl`, present on every Mac) and import that into a small dedicated keychain —
/// never the user's login keychain — via `SecPKCS12Import`.
enum TLSIdentity {
    /// Builds a `sec_identity_t` from a PEM cert+key pair, backed by a fresh keychain file
    /// under `directory` that must persist for as long as the returned identity is in use
    /// (Network.framework holds a reference into it, not a copy) — call this once per
    /// listener start, not per request. Stale keychain files from earlier calls (e.g. a
    /// prior app launch) are swept first so they don't accumulate forever.
    static func make(certPEM: String, keyPEM: String, in directory: URL) -> sec_identity_t? {
        sweepStaleKeychains(in: directory)
        guard let p12Data = pkcs12(certPEM: certPEM, keyPEM: keyPEM, passphrase: passphrase) else { return nil }

        let keychainPath = directory.appendingPathComponent("remote-tls-\(UUID().uuidString).keychain-db").path
        var keychain: SecKeychain?
        guard SecKeychainCreate(keychainPath, UInt32(passphrase.utf8.count), passphrase,
                                false, nil, &keychain) == errSecSuccess,
              let kc = keychain else { return nil }

        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase,
                                      kSecImportExportKeychain as String: kc]
        var rawItems: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems) == errSecSuccess,
              let items = rawItems as? [[String: Any]], let first = items.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }

        return sec_identity_create(identity as! SecIdentity)
    }

    // Protects the ephemeral keychain file for the moment it exists on disk — not a
    // secret anyone needs to remember, so a fresh one per process launch is fine; nothing
    // needs to reopen an old keychain file since `make` always builds a new one.
    private static let passphrase = UUID().uuidString

    private static func sweepStaleKeychains(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in contents where name.hasPrefix("remote-tls-") && name.hasSuffix(".keychain-db") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func pkcs12(certPEM: String, keyPEM: String, passphrase: String) -> Data? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-isle-p12-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let certPath = dir.appendingPathComponent("cert.pem").path
        let keyPath = dir.appendingPathComponent("key.pem").path
        let p12Path = dir.appendingPathComponent("identity.p12").path
        do {
            try certPEM.write(toFile: certPath, atomically: true, encoding: .utf8)
            try keyPEM.write(toFile: keyPath, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["pkcs12", "-export", "-in", certPath, "-inkey", keyPath,
                             "-out", p12Path, "-passout", "pass:\(passphrase)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
        } catch {
            return nil
        }
        return FileManager.default.contents(atPath: p12Path)
    }
}
