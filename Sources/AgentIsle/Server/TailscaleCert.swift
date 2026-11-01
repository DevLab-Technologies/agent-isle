import Foundation

/// Obtains an HTTPS certificate for this Mac's Tailscale MagicDNS name via the `tailscale`
/// CLI, so `RemoteActionServer` can serve the Tailscale link over real HTTPS instead of
/// plain HTTP — which is also what unlocks browser notifications on the mobile page,
/// since the `Notification` API needs a secure context.
///
/// Requires MagicDNS and "HTTPS Certificates" enabled for the tailnet (Tailscale admin
/// console → DNS). When either isn't on, or Tailscale isn't installed at all, every
/// function here just yields nil and the Tailscale link stays plain HTTP, same as before
/// this existed — this is additive, never a hard requirement.
enum TailscaleCert {
    struct Cert {
        let certPEM: String
        let keyPEM: String
        let dnsName: String
        let expiresAt: Date
    }

    /// Finds the installed `tailscale`/`Tailscale` CLI binary. There's no `$PATH`
    /// guarantee for a GUI app, so the common install locations are checked directly.
    private static func binaryPath() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/bin/tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// This device's MagicDNS name (e.g. `my-mac.tailnet-name.ts.net`), or nil if
    /// Tailscale isn't running or MagicDNS isn't configured for the tailnet.
    static func magicDNSName() -> String? {
        guard let bin = binaryPath(), let data = run(bin, ["status", "--json"]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfObj = obj["Self"] as? [String: Any],
              var name = selfObj["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Obtains (or renews) a cert for `dnsName`. This is slow — a first issuance is a
    /// real network round trip to Tailscale's CA, observed to take ~20–30s — so this must
    /// only ever be called off the main thread/actor.
    static func obtain(dnsName: String) -> Cert? {
        guard let bin = binaryPath() else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-isle-tls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let certPath = dir.appendingPathComponent("cert.pem").path
        let keyPath = dir.appendingPathComponent("key.pem").path
        guard run(bin, ["cert", "--cert-file", certPath, "--key-file", keyPath, dnsName]) != nil,
              let certPEM = try? String(contentsOfFile: certPath, encoding: .utf8),
              let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let expiresAt = expiry(ofPEM: certPEM) else { return nil }
        return Cert(certPEM: certPEM, keyPEM: keyPEM, dnsName: dnsName, expiresAt: expiresAt)
    }

    /// Runs a subprocess and returns its stdout, or nil on a non-zero exit or launch
    /// failure. Reads stdout *before* waiting on exit, since waiting first risks a
    /// deadlock if the child fills the pipe buffer before anything drains it.
    private static func run(_ bin: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    /// The certificate's `notAfter` date, via `openssl x509` — Foundation has no X.509
    /// parser, and this is the one field needed (renewal timing), not full validation.
    /// Internal rather than private: `RemoteActionServer` reuses this to check a cached
    /// cert's expiry before deciding whether to re-fetch.
    static func expiry(ofPEM pem: String) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-noout", "-enddate"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(pem.utf8))
            input.fileHandleForWriting.closeFile()
            let outData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: outData, encoding: .utf8),
                  let dateString = text.split(separator: "=").last else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
            return formatter.date(from: dateString.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return nil
        }
    }
}
