import Foundation
import Network

/// One address the mobile page is reachable at, and the token-scoped URL to reach it.
struct RemoteAccessLink {
    struct Endpoint {
        let kind: NetworkInterfaces.Address.Kind
        let url: URL
    }
    let endpoints: [Endpoint]
}

/// Serves a small mobile-facing page so any session's pending permission/question/plan
/// prompt can be approved from a phone — over the LAN or over Tailscale — without any
/// external backend.
///
/// Unlike `EventServer` (deliberately pinned to `127.0.0.1`), this listener binds every
/// interface: reachability from another device is the whole point. Tailscale needs no
/// special handling here — once connected it just presents as another interface with an
/// IP in `100.64.0.0/10`, which `NetworkInterfaces` already detects, so the same listener
/// serves both the LAN and Tailscale paths.
///
/// The link is a single standing pairing rather than one per prompt: scanning it once
/// lets the phone act on *any* session's current or future prompt, not just whatever was
/// pending at scan time. The security boundary is that pairing token instead of the
/// network binding — random, revocable from the Mac at any time ("Disconnect"), bounded
/// by a TTL, and covering only three fixed routes (no listing endpoint beyond the
/// sessions with something actually pending). The phone is only ever offered
/// Allow-Once/Deny for a permission — never "Always Allow"/"Bypass" — so a leaked link
/// can't grant standing auto-approval for a session.
///
/// The token itself survives an app restart (persisted in `UserDefaults`, not just held
/// in memory) and the listener resumes automatically on launch if one is still valid —
/// otherwise a routine relaunch (an auto-update, a reboot) would silently break a link
/// the user already scanned and is relying on, with no way to fix it except walking back
/// to the Mac. Before that first pairing, though, nothing starts unprompted — the
/// listener only comes up the first time "Connect phone" is tapped, or on a later launch
/// that finds a pairing already on record.
@MainActor
final class RemoteActionServer {
    static let shared = RemoteActionServer()

    static let port: UInt16 = 4712
    static let httpsPort: UInt16 = 4713
    // Large enough for a phone photo as base64 (~33% larger than the original file) —
    // every other route's body is a few hundred bytes at most, so this only matters for
    // the image-upload route.
    static let maxRequestSize = 16 * 1024 * 1024
    // Long enough that a real, relied-upon pairing (e.g. away from home for a few weeks)
    // doesn't quietly expire out from under the user — "Disconnect" is the intended way
    // to end one deliberately, this is just a backstop.
    private static let tokenTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let defaultsKey = "RemoteActionServer.pairing"
    nonisolated private static let tlsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-isle/tls")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var listener: NWListener?
    private var httpsListener: NWListener?
    private var tailscaleHTTPS: (dnsName: String, expiresAt: Date)?
    private var tailscaleSetupStarted = false
    private weak var store: SessionStore?
    private var activeToken: (token: String, expiresAt: Date)? {
        didSet { persistToken() }
    }

    private init() {
        activeToken = Self.loadPersistedToken()
    }

    /// Resumes a still-valid pairing from a prior launch, so the phone's already-scanned
    /// link keeps working across a restart instead of going dark until someone reopens
    /// the popover on the Mac itself.
    func attach(to store: SessionStore) {
        self.store = store
        if activeToken != nil { start() }
    }

    var isConnected: Bool {
        guard let activeToken else { return false }
        return activeToken.expiresAt > Date()
    }

    /// The current pairing link, minting one only if none is active (or the previous one
    /// expired) — reopening this popover shows the same link rather than silently
    /// invalidating whatever the phone already scanned. Starts the listener (and kicks
    /// off Tailscale HTTPS setup in the background, see `setUpTailscaleHTTPSIfNeeded`) on
    /// first call; returns nil if it can't start or no interface (LAN/Tailscale) is
    /// reachable. `async` so the caller can show a placeholder first — this itself
    /// resolves quickly, but callers shouldn't assume every future version of it will.
    func currentLink() async -> RemoteAccessLink? {
        guard store != nil else { return nil }
        if listener == nil { start() }
        guard listener != nil else { return nil }

        let token: String
        if let activeToken, activeToken.expiresAt > Date() {
            token = activeToken.token
        } else {
            token = Self.randomToken()
            activeToken = (token, Date().addingTimeInterval(Self.tokenTTL))
        }
        return link(for: token)
    }

    /// Revoke the current pairing — the phone's link stops working immediately.
    func disconnect() {
        activeToken = nil
    }

    private static func loadPersistedToken() -> (token: String, expiresAt: Date)? {
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey),
              let token = saved["token"] as? String,
              let expiresAt = saved["expiresAt"] as? Double else { return nil }
        let expiry = Date(timeIntervalSince1970: expiresAt)
        return expiry > Date() ? (token, expiry) : nil
    }

    private func persistToken() {
        guard let activeToken else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        UserDefaults.standard.set(["token": activeToken.token,
                                   "expiresAt": activeToken.expiresAt.timeIntervalSince1970],
                                  forKey: Self.defaultsKey)
    }

    private func link(for token: String) -> RemoteAccessLink? {
        let addresses = NetworkInterfaces.reachableAddresses()
        guard !addresses.isEmpty else { return nil }
        let endpoints = addresses.compactMap { addr -> RemoteAccessLink.Endpoint? in
            // Prefer the Tailscale HTTPS listener once it's ready — real TLS against the
            // MagicDNS name, not just the plain-HTTP fallback every link starts as.
            if addr.kind == .tailscale, let https = tailscaleHTTPS, https.expiresAt > Date(),
               let url = URL(string: "https://\(https.dnsName):\(Self.httpsPort)/r/\(token)") {
                return RemoteAccessLink.Endpoint(kind: .tailscale, url: url)
            }
            guard let url = URL(string: "http://\(addr.host):\(Self.port)/r/\(token)") else { return nil }
            return RemoteAccessLink.Endpoint(kind: addr.kind, url: url)
        }
        return endpoints.isEmpty ? nil : RemoteAccessLink(endpoints: endpoints)
    }

    // MARK: - Tailscale HTTPS

    /// Kicks off Tailscale HTTPS setup at most once per launch, entirely in the
    /// background — cheap if a cached, still-valid cert exists (just rebuilds the
    /// ephemeral keychain identity, well under a second), slow (~20–30s, a real network
    /// round trip to Tailscale's CA) only the first time or when renewing near expiry.
    /// Never blocks `currentLink()`: the Tailscale endpoint just stays plain HTTP for any
    /// call made before this finishes, and upgrades to HTTPS on the next one after.
    /// Silently does nothing if Tailscale isn't installed or HTTPS certs aren't enabled
    /// for the tailnet.
    private func setUpTailscaleHTTPSIfNeeded() {
        guard !tailscaleSetupStarted else { return }
        tailscaleSetupStarted = true
        Task.detached(priority: .utility) { [weak self] in
            guard let prepared = Self.prepareTailscaleHTTPS() else { return }
            await self?.startHTTPSListener(prepared)
        }
    }

    private struct PreparedCert {
        let certPEM: String
        let keyPEM: String
        let dnsName: String
        let expiresAt: Date
    }

    /// Runs entirely off the main actor (called from a detached `Task`): reuses a cached
    /// cert from a prior launch if it's still comfortably valid, otherwise fetches or
    /// renews one via `TailscaleCert` — the slow path.
    nonisolated private static func prepareTailscaleHTTPS() -> PreparedCert? {
        guard let dnsName = TailscaleCert.magicDNSName() else { return nil }
        let certPath = tlsDirectory.appendingPathComponent("cert.pem")
        let keyPath = tlsDirectory.appendingPathComponent("key.pem")
        let renewalBuffer: TimeInterval = 7 * 24 * 60 * 60

        if let cachedCert = try? String(contentsOf: certPath, encoding: .utf8),
           let cachedKey = try? String(contentsOf: keyPath, encoding: .utf8),
           let cachedExpiry = TailscaleCert.expiry(ofPEM: cachedCert),
           cachedExpiry.timeIntervalSinceNow > renewalBuffer {
            return PreparedCert(certPEM: cachedCert, keyPEM: cachedKey, dnsName: dnsName, expiresAt: cachedExpiry)
        }

        guard let cert = TailscaleCert.obtain(dnsName: dnsName) else { return nil }
        try? cert.certPEM.write(to: certPath, atomically: true, encoding: .utf8)
        try? cert.keyPEM.write(to: keyPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        return PreparedCert(certPEM: cert.certPEM, keyPEM: cert.keyPEM, dnsName: cert.dnsName, expiresAt: cert.expiresAt)
    }

    private func startHTTPSListener(_ prepared: PreparedCert) {
        guard httpsListener == nil else {
            tailscaleHTTPS = (prepared.dnsName, prepared.expiresAt)
            return
        }
        guard let identity = TLSIdentity.make(certPEM: prepared.certPEM, keyPEM: prepared.keyPEM,
                                              in: Self.tlsDirectory) else {
            NSLog("RemoteActionServer: couldn't build a TLS identity from the Tailscale cert")
            return
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        let params = NWParameters(tls: tlsOptions, tcp: .init())
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.httpsPort)!)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("RemoteActionServer HTTPS failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                conn.stateUpdateHandler = { state in
                    if case .failed(let error) = state { NSLog("RemoteActionServer HTTPS conn failed: \(error)") }
                }
                conn.start(queue: .main)
                Task { @MainActor [weak self] in self?.receive(on: conn) }
            }
            listener.start(queue: .main)
            self.httpsListener = listener
            self.tailscaleHTTPS = (prepared.dnsName, prepared.expiresAt)
            NSLog("RemoteActionServer HTTPS listening on :\(Self.httpsPort) for \(prepared.dnsName)")
        } catch {
            NSLog("RemoteActionServer HTTPS could not start: \(error)")
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Listener

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("RemoteActionServer failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                conn.stateUpdateHandler = { state in
                    if case .failed(let error) = state { NSLog("RemoteActionServer conn failed: \(error)") }
                }
                conn.start(queue: .main)
                Task { @MainActor [weak self] in self?.receive(on: conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("RemoteActionServer listening on :\(Self.port)")
        } catch {
            NSLog("RemoteActionServer could not start: \(error)")
        }
        setUpTailscaleHTTPSIfNeeded()
    }

    // MARK: - Request handling

    private func receive(on conn: NWConnection) {
        var buffer = Data()

        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard let data, !data.isEmpty else {
                        if isComplete || error != nil { conn.cancel() }
                        return
                    }

                    buffer.append(data)
                    guard buffer.count <= Self.maxRequestSize else {
                        self.respondBadRequest(conn); return
                    }

                    switch HTTPFraming.requestLength(in: buffer, maxRequestSize: Self.maxRequestSize,
                                                     requireContentLength: false) {
                    case .incompleteHeaders:
                        if isComplete { self.respondBadRequest(conn) } else { readMore() }
                    case .invalid:
                        self.respondBadRequest(conn)
                    case .complete(let length):
                        if buffer.count >= length {
                            self.handleRequest(Data(buffer.prefix(length)), on: conn)
                        } else if isComplete {
                            self.respondBadRequest(conn)
                        } else {
                            readMore()
                        }
                    }
                }
            }
        }

        readMore()
    }

    private func handleRequest(_ data: Data, on conn: NWConnection) {
        guard let (method, path) = HTTPFraming.requestLine(in: data) else {
            respondBadRequest(conn); return
        }
        // /r/<token>[/decision|/answer|/plan|/state|/history/<sessionID>]
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, segments[0] == "r" else { respondNotFound(conn); return }
        let token = segments[1]
        let action = segments.count >= 3 ? segments[2] : nil
        let body = HTTPFraming.body(of: data)

        guard let activeToken, activeToken.token == token, activeToken.expiresAt > Date() else {
            respondGone(conn); return
        }

        switch (method, action) {
        case ("GET", nil):
            respondHTML(conn)
        case ("GET", "state"):
            respondState(conn)
        case ("GET", "history"):
            guard segments.count >= 4, let sessionID = UUID(uuidString: segments[3]) else {
                respondBadRequest(conn); return
            }
            respondHistory(conn, sessionID: sessionID)
        case ("POST", "decision"):
            handleDecision(body: body, conn: conn)
        case ("POST", "answer"):
            handleAnswer(body: body, conn: conn)
        case ("POST", "plan"):
            handlePlan(body: body, conn: conn)
        case ("POST", "message"):
            handleMessage(body: body, conn: conn)
        case ("POST", "image"):
            handleImage(body: body, conn: conn)
        default:
            respondNotFound(conn)
        }
    }

    // MARK: - Actions

    /// Every action targets an explicit `session` — one pairing link covers every session,
    /// so the phone's request always says which one it means.
    private func targetSession(_ obj: [String: Any]?) -> UUID? {
        (obj?["session"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func handleDecision(body: Data, conn: NWConnection) {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let store, let sessionID = targetSession(obj),
              let decision = obj?["decision"] as? String else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.permission != nil else {
            respondGone(conn); return
        }
        // The phone offers only the two least-consequential decisions — never
        // "Always"/"Bypass" — so a leaked link can approve/deny one call, not grant
        // standing auto-approval for the session. Fails closed: anything but an exact
        // "allow" denies, matching `EventServer.reply`'s own fail-closed fallback.
        store.resolvePermission(sessionID: sessionID, decision: decision == "allow" ? .allowOnce : .deny)
        respondJSON(conn, ["ok": true])
    }

    private func handleAnswer(body: Data, conn: NWConnection) {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let store, let sessionID = targetSession(obj),
              let text = obj?["text"] as? String else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.question != nil else {
            respondGone(conn); return
        }
        store.answerQuestion(sessionID: sessionID, answer: text)
        respondJSON(conn, ["ok": true])
    }

    private func handlePlan(body: Data, conn: NWConnection) {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let store, let sessionID = targetSession(obj) else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.plan != nil else {
            respondGone(conn); return
        }
        let feedback = ((obj?["feedback"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if feedback.isEmpty {
            store.approvePlan(sessionID: sessionID)
        } else {
            store.sendPlanFeedback(sessionID: sessionID, feedback: feedback)
        }
        respondJSON(conn, ["ok": true])
    }

    /// Send a free-form message into a session's terminal — the same best-effort delivery
    /// `SessionChatView`'s composer uses on macOS (typed into the host app; not confirmed
    /// delivered). Unlike the other actions this isn't answering a specific prompt, so it
    /// has no pending-state guard: any session can be messaged at any time.
    private func handleMessage(body: Data, conn: NWConnection) {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let store, let sessionID = targetSession(obj), let text = obj?["text"] as? String,
              let session = store.sessions.first(where: { $0.id == sessionID }) else {
            respondBadRequest(conn); return
        }
        store.sendMessage(text, to: session)
        respondJSON(conn, ["ok": true])
    }

    /// Saves an uploaded image to disk and sends a message referencing its path — there's
    /// no generic "attach an image" channel into a terminal-based agent the way a chat app
    /// has, so the agent sees it the same way it'd see a path the user typed, and can
    /// `Read` it if it chooses to. Delivery is the same best-effort typing `sendMessage`
    /// always uses.
    private func handleImage(body: Data, conn: NWConnection) {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let store, let sessionID = targetSession(obj),
              let base64 = obj?["data"] as? String, let imageData = Data(base64Encoded: base64),
              let session = store.sessions.first(where: { $0.id == sessionID }) else {
            respondBadRequest(conn); return
        }
        let ext = Self.fileExtension(forMIME: obj?["mime"] as? String)
        let fileURL = Self.uploadsDirectory.appendingPathComponent("photo-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
        guard (try? imageData.write(to: fileURL)) != nil else { respondBadRequest(conn); return }
        store.sendMessage("Image attached: \(fileURL.path)", to: session)
        respondJSON(conn, ["ok": true])
    }

    nonisolated private static let uploadsDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-isle/uploads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated private static func fileExtension(forMIME mime: String?) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic", "image/heif": return "heic"
        default: return "jpg"
        }
    }

    /// Every session across the store, mirroring what the macOS island itself shows — the
    /// phone polls this rather than just the sessions with something pending, since one
    /// pairing link covers all of them and the client needs the full list to notice a
    /// status change (e.g. "done") worth notifying about, not only new prompts. A
    /// multi-part question only shows its first part, matching the simplification the
    /// demo/simple-producer path already makes for this wire format.
    private func respondState(_ conn: NWConnection) {
        guard let store else { respondJSON(conn, ["sessions": []]); return }
        let sessions: [[String: Any]] = store.sessions.map { session in
            var obj: [String: Any] = ["session": session.id.uuidString,
                                      "title": session.title,
                                      "agent": session.agent.displayName,
                                      "status": session.status.rawValue,
                                      "statusLabel": session.status.label,
                                      "lastMessage": session.lastMessage,
                                      "tokens": session.tokens]
            if let model = session.model { obj["model"] = model }
            // `status` reflects recent transcript activity, not the todo list — a session
            // can sit at "Idle" between tool calls while several tasks are still in
            // progress, so the task list is what actually explains that to the user (the
            // macOS island shows both for the same reason).
            if !session.tasks.isEmpty {
                obj["tasks"] = ["done": session.tasks.done, "inProgress": session.tasks.inProgress,
                                "open": session.tasks.open, "total": session.tasks.total,
                                "items": session.tasks.ordered.map { item -> [String: Any] in
                                    ["text": item.text, "state": item.state.rawValue]
                                }]
            }
            if let p = session.permission {
                var prompt: [String: Any] = ["kind": "permission", "tool": p.toolName]
                if let command = p.command { prompt["command"] = command }
                if let path = p.filePath { prompt["path"] = path }
                obj["prompt"] = prompt
            } else if let q = session.question, let part = q.parts.first {
                obj["prompt"] = ["kind": "question", "prompt": part.prompt,
                                 "options": part.options, "allowsOther": part.allowsOther]
            } else if let plan = session.plan {
                obj["prompt"] = ["kind": "plan", "markdown": plan.markdown]
            }
            return obj
        }
        respondJSON(conn, ["sessions": sessions])
    }

    /// A session's conversation, read the same way the macOS chat view does — via
    /// `ChatHistory`, which knows each agent's on-disk transcript format. Best-effort like
    /// its every caller: an unsupported agent or a session with no transcript file yet
    /// just yields an empty/`unsupported` result rather than an error.
    private func respondHistory(_ conn: NWConnection, sessionID: UUID) {
        guard let store, let session = store.sessions.first(where: { $0.id == sessionID }) else {
            respondJSON(conn, ["messages": []]); return
        }
        guard ChatHistory.isSupported(session.agent), let url = session.transcriptURL else {
            respondJSON(conn, ["messages": [], "unsupported": true]); return
        }
        let messages = ChatHistory.messages(for: session.agent, url: url).filter { !$0.isEmpty }
        let out = messages.map { message -> [String: Any] in
            var obj: [String: Any] = ["role": message.role == .user ? "user" : "assistant",
                                      "blocks": Self.encode(message.blocks)]
            if let ts = message.timestamp { obj["timestamp"] = ts.timeIntervalSince1970 * 1000 }
            return obj
        }
        respondJSON(conn, ["messages": out, "tokens": session.tokens])
    }

    /// Keeps each block's kind rather than flattening to plain text, so the mobile page
    /// can style thinking/tool-use/tool-result the way `ChatMessageView` does on macOS
    /// instead of running everything together as one paragraph.
    private static func encode(_ blocks: [ChatBlock]) -> [[String: Any]] {
        blocks.map { block in
            switch block {
            case .text(let s):       return ["kind": "text", "text": s]
            case .notice(let s):     return ["kind": "notice", "text": s]
            case .thinking(let s):   return ["kind": "thinking", "text": s]
            case .toolResult(let s): return ["kind": "toolResult", "text": s]
            case .toolUse(let name, let detail):
                var obj: [String: Any] = ["kind": "toolUse", "name": name]
                if let detail { obj["detail"] = detail }
                return obj
            }
        }
    }

    // MARK: - Responses

    private func respondJSON(_ conn: NWConnection, _ obj: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        respond(on: conn, status: 200, contentType: "application/json", body: data)
    }

    private func respondHTML(_ conn: NWConnection) {
        respond(on: conn, status: 200, contentType: "text/html; charset=utf-8", body: Data(Self.pageHTML.utf8))
    }

    private func respondBadRequest(_ conn: NWConnection) {
        respond(on: conn, status: 400, contentType: "application/json",
               body: Data(#"{"ok":false,"error":"bad request"}"#.utf8))
    }

    private func respondNotFound(_ conn: NWConnection) {
        respond(on: conn, status: 404, contentType: "application/json",
               body: Data(#"{"ok":false,"error":"not found"}"#.utf8))
    }

    private func respondGone(_ conn: NWConnection) {
        respond(on: conn, status: 410, contentType: "application/json",
               body: Data(#"{"ok":false,"error":"expired"}"#.utf8))
    }

    private func respond(on conn: NWConnection, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 410: reason = "Gone"
        default: reason = "OK"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Mobile page

    /// Self-contained HTML/JS — no external assets, matching the app's no-dependency rule.
    /// Polls `/r/<token>/state` for every session (mirroring the macOS island) and posts
    /// back to `/r/<token>/{decision,answer,plan}` with an explicit `session` id.
    ///
    /// Notifications are the browser `Notification` API driven by that same poll loop —
    /// there's no push infrastructure behind this (no server-sent push, no service worker).
    /// That means they only fire while this page is open (foreground, or briefly
    /// backgrounded) — never when the phone is locked or the tab's fully closed, and
    /// (iOS Safari specifically) only after the page is added to the Home Screen at all,
    /// and only over HTTPS on most browsers. True background push would need a Home
    /// Screen–installed PWA, HTTPS, and the Web Push protocol implemented Mac-side —
    /// a much bigger lift than what's here.
    private static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Agent Isle</title>
    <style>
      :root { color-scheme: dark; }
      body { font-family: -apple-system, system-ui, sans-serif; background:#0b0b0d; color:#eee;
             margin:0; padding:20px; }
      h1 { font-size:13px; opacity:.5; text-transform:uppercase; letter-spacing:.08em; margin:0 0 14px;
           display:flex; align-items:center; justify-content:space-between; }
      .bell { background:none; border:none; color:#5cd48c; font:inherit; text-transform:none;
              letter-spacing:normal; padding:0; width:auto; margin:0; display:inline; }
      .bell.muted { color:#666; }
      .row { background:#17171a; border-radius:12px; padding:14px 16px; margin-bottom:10px;
             display:flex; flex-direction:column; gap:2px; }
      .card { background:#17171a; border-radius:12px; padding:16px; margin-bottom:12px; }
      .head { font-size:11px; opacity:.55; margin-bottom:6px; }
      .agent { color:#f5b74d; font-weight:600; }
      .tool { color:#f5b74d; font-weight:600; margin-bottom:6px; }
      .status { font-size:11px; opacity:.6; }
      .last { font-size:13px; opacity:.85; }
      .tasks { margin-top:8px; padding-top:8px; border-top:1px solid #222; }
      .tasksSummary { font-size:10.5px; opacity:.5; text-transform:uppercase; letter-spacing:.03em;
                      margin-bottom:4px; }
      .taskItem { font-size:12.5px; padding:2px 0; }
      .taskItem.completed { opacity:.4; text-decoration:line-through; }
      .taskItem.inProgress { color:#5cd48c; font-weight:600; }
      .taskItem.pending { opacity:.7; }
      .taskItem.more { opacity:.4; font-style:italic; }
      pre { white-space:pre-wrap; word-break:break-word; background:#000; padding:10px;
            border-radius:8px; font-size:13px; margin:6px 0 0; }
      button { display:block; width:100%; padding:14px; margin:8px 0 0; border:none;
               border-radius:10px; font-size:16px; font-weight:600; }
      .allow { background:#5cd48c; color:#000; }
      .deny { background:#f36b6b; color:#000; }
      .opt { background:#26262b; color:#eee; text-align:left; }
      textarea { width:100%; box-sizing:border-box; background:#000; color:#eee;
                 border:1px solid #333; border-radius:8px; padding:10px; font-size:15px; margin-top:8px; }
      .empty { text-align:center; opacity:.5; padding:60px 0; font-size:14px; }
      .hint { font-size:11px; opacity:.4; text-align:center; margin-top:14px; }
      .hist { float:right; color:#5cd48c; font-weight:600; text-decoration:none; }
      /* Fixed header + fixed composer, only the message list itself scrolls — the back
         button and the send box must stay reachable without scrolling past messages. */
      #overlay { display:none; flex-direction:column; position:fixed; inset:0; background:#0b0b0d;
                 z-index:10; }
      .histHead { flex:0 0 auto; display:flex; align-items:center; gap:10px;
                  padding:14px 16px; border-bottom:1px solid #222; }
      .histTitle { font-size:13px; font-weight:600; opacity:.8; }
      .histStatus { font-size:10px; font-weight:600; opacity:.6; margin-left:6px; text-transform:uppercase; }
      .back { width:auto; padding:8px 14px; margin:0; background:#26262b; color:#eee;
              border-radius:8px; font-size:14px; }
      #historyBody { flex:1 1 auto; overflow-y:auto; padding:16px; }
      .msg { display:flex; margin-bottom:10px; }
      .msg.user { justify-content:flex-end; }
      .bubble { max-width:78%; padding:10px 13px; border-radius:16px; font-size:14.5px;
                line-height:1.35; white-space:pre-wrap; word-break:break-word; }
      .msg.assistant .bubble { background:#26262b; color:#eee; border-bottom-left-radius:4px; }
      .msg.user .bubble { background:#3d8bfd; color:#fff; border-bottom-right-radius:4px; }
      .time { font-size:10px; opacity:.55; margin-top:4px; }
      .blk { margin-bottom:6px; }
      .blk:last-child { margin-bottom:0; }
      .blk.notice { opacity:.55; font-size:12.5px; font-style:italic; }
      .blk.thinking { opacity:.55; font-size:13px; font-style:italic; }
      .blk.tool { font-size:13px; font-weight:600; color:#f5b74d; }
      .blk.toolresult { font-size:12px; opacity:.75; font-family:ui-monospace, monospace;
                        background:rgba(0,0,0,.25); padding:6px 8px; border-radius:6px; }
      .composer { flex:0 0 auto; display:flex; gap:8px; padding:10px 12px;
                  padding-bottom:max(10px, env(safe-area-inset-bottom));
                  border-top:1px solid #222; background:#0b0b0d; }
      .composer input { flex:1 1 auto; background:#17171a; color:#eee; border:1px solid #333;
                        border-radius:20px; padding:11px 15px; font-size:15px; min-width:0; }
      .composer button { width:auto; flex:0 0 auto; margin:0; padding:0 18px;
                         border-radius:20px; background:#5cd48c; color:#000; font-size:14px; }
      .composer button.attach { padding:0 10px; background:#26262b; font-size:18px; }
      .composer button.attach:disabled { opacity:.5; }
    </style></head><body>
    <h1>Agent Isle <button class="bell" id="bell" onclick="toggleNotifications()">…</button></h1>
    <div id="root" class="empty">Loading…</div>
    <div class="hint" id="hint"></div>
    <div id="overlay">
      <div class="histHead">
        <button class="back" onclick="closeHistory()">← Back</button>
        <span class="histTitle" id="historyTitle"></span>
      </div>
      <div id="historyBody"></div>
      <div class="composer">
        <button class="attach" onclick="document.getElementById('imagePicker').click()">📷</button>
        <input type="file" id="imagePicker" accept="image/*" style="display:none" onchange="sendChatImage(this)">
        <input id="composerInput" placeholder="Message…"
               onkeydown="if(event.key==='Enter'){event.preventDefault();sendChatMessage();}">
        <button onclick="sendChatMessage()">Send</button>
      </div>
    </div>
    <script>
    const token = location.pathname.split('/')[2];
    const seen = {}; // session id -> {status} last observed, for notify-on-change
    function esc(s) { return (s||'').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
    // For interpolating a JS call into an onclick attribute: escapes quotes too, so option
    // text containing an apostrophe (e.g. "Don't deploy") can't break out of the attribute.
    function escAttr(s) { return (s||'').replace(/[&<>'"]/g,
      c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c])); }
    async function post(path, body) {
      try {
        const r = await fetch(`/r/${token}/${path}`, {
          method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body || {})
        });
        return r.ok;
      } catch (e) { return false; }
    }
    function notify(title, body) {
      if (!('Notification' in window) || Notification.permission !== 'granted') return;
      try {
        const n = new Notification(title, {body, tag: title});
        n.onclick = () => { window.focus(); n.close(); };
      } catch (e) {}
    }
    function updateBell() {
      const bell = document.getElementById('bell');
      const hint = document.getElementById('hint');
      if (!('Notification' in window)) {
        bell.textContent = '🔕 Notifications unavailable'; bell.className = 'bell muted';
        hint.textContent =
          'Notifications need HTTPS on this browser — not available over this plain-HTTP link.';
        return;
      }
      if (Notification.permission === 'granted') {
        bell.textContent = '🔔 Notifications on'; bell.className = 'bell';
        hint.textContent = '';
      } else if (Notification.permission === 'denied') {
        bell.textContent = '🔕 Notifications blocked'; bell.className = 'bell muted';
        hint.textContent = 'Re-enable them for this site in your browser settings.';
      } else {
        bell.textContent = '🔔 Enable notifications'; bell.className = 'bell';
        hint.textContent = 'On iPhone: add this page to your Home Screen first, or notifications won\\'t fire.';
      }
    }
    function toggleNotifications() {
      if (!('Notification' in window) || Notification.permission === 'denied') return;
      Notification.requestPermission().then(updateBell);
    }
    function promptHTML(sid, p) {
      if (p.kind === 'permission') {
        return `<div class="tool">${esc(p.tool)}</div>` +
          (p.path ? `<div>${esc(p.path)}</div>` : '') +
          (p.command ? `<pre>${esc(p.command)}</pre>` : '') +
          `<button class="allow" onclick="decide('${sid}','allow')">Allow Once</button>` +
          `<button class="deny" onclick="decide('${sid}','deny')">Deny</button>`;
      }
      if (p.kind === 'question') {
        const opts = (p.options || []).map(o => {
          const call = `answer(${JSON.stringify(sid)}, ${JSON.stringify(o)})`;
          return `<button class="opt" onclick="${escAttr(call)}">${esc(o)}</button>`;
        }).join('');
        return `<div>${esc(p.prompt)}</div>${opts}` +
          (p.allowsOther
            ? `<textarea id="other-${sid}" placeholder="Or type an answer…"></textarea>` +
              `<button class="opt" onclick="answer('${sid}', document.getElementById('other-${sid}').value)">Send</button>`
            : '');
      }
      if (p.kind === 'plan') {
        return `<pre>${esc(p.markdown)}</pre>` +
          `<button class="allow" onclick="plan('${sid}','')">Approve</button>` +
          `<textarea id="fb-${sid}" placeholder="Or send feedback…"></textarea>` +
          `<button class="opt" onclick="plan('${sid}', document.getElementById('fb-${sid}').value)">Send Feedback</button>`;
      }
      return '';
    }
    function taskGlyph(state) {
      return state === 'completed' ? '✓' : state === 'inProgress' ? '●' : '○';
    }
    // Mirrors TaskListView's own truncation on macOS: active items first, completed ones
    // fill the rest up to 5, and whatever's left collapses into one footer line — a long
    // todo list shouldn't blow out a phone screen either.
    function visibleTasks(t) {
      const cap = 5;
      const active = t.items.filter(i => i.state !== 'completed');
      const completed = t.items.filter(i => i.state === 'completed');
      return active.length >= cap ? active.slice(0, cap) : active.concat(completed.slice(0, cap - active.length));
    }
    function tasksHTML(t) {
      if (!t) return '';
      const visible = visibleTasks(t);
      const hidden = t.total - visible.length;
      const hiddenCompleted = t.done - visible.filter(i => i.state === 'completed').length;
      const items = visible.map(i =>
        `<div class="taskItem ${i.state}">${taskGlyph(i.state)} ${esc(i.text)}</div>`).join('');
      const footer = hidden > 0
        ? `<div class="taskItem more">+${hidden} ${hidden === hiddenCompleted ? 'completed' : 'more'}</div>` : '';
      return `<div class="tasks">` +
        `<div class="tasksSummary">Tasks · ${t.done} done · ${t.inProgress} in progress · ${t.open} open</div>` +
        items + footer + `</div>`;
    }
    function formatTokensJS(n) {
      if (!n) return '0';
      if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
      if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
      return String(n);
    }
    function statusLine(s) {
      const parts = [s.statusLabel];
      if (s.model) parts.push(s.model);
      if (s.tokens) parts.push(formatTokensJS(s.tokens) + ' tok');
      return parts.map(esc).join(' · ');
    }
    function sessionHTML(s) {
      const head = `<div class="head"><span class="agent">${esc(s.agent)}</span> · ${esc(s.title)}` +
        ` <a class="hist" onclick="openHistory('${s.session}')">Chat →</a></div>`;
      if (s.prompt) {
        return `<div class="card">${head}${promptHTML(s.session, s.prompt)}${tasksHTML(s.tasks)}</div>`;
      }
      return `<div class="row">${head}` +
        `<div class="status">${statusLine(s)}</div>` +
        `<div class="last">${esc(s.lastMessage)}</div>${tasksHTML(s.tasks)}</div>`;
    }
    const sessionsById = {}; // refreshed every poll, so the open chat header stays live
    function timeLabel(ms) {
      if (!ms) return '';
      return new Date(ms).toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
    }
    let historySession = null;
    function updateHistoryHeader() {
      const s = sessionsById[historySession];
      document.getElementById('historyTitle').innerHTML = s
        ? `${esc(s.title)} <span class="histStatus">${statusLine(s)}</span>` : '';
    }
    async function openHistory(sid) {
      historySession = sid;
      document.getElementById('overlay').style.display = 'flex';
      document.getElementById('historyBody').innerHTML = '<div class="empty">Loading…</div>';
      document.getElementById('composerInput').value = '';
      updateHistoryHeader();
      await loadHistory();
    }
    function closeHistory() {
      historySession = null;
      document.getElementById('overlay').style.display = 'none';
    }
    async function loadHistory() {
      if (!historySession) return;
      try {
        const r = await fetch(`/r/${token}/history/${historySession}`);
        const data = await r.json();
        renderHistory(data.messages || [], data.unsupported);
      } catch (e) {}
    }
    async function sendChatMessage() {
      if (!historySession) return;
      const input = document.getElementById('composerInput');
      const text = input.value.trim();
      if (!text) return;
      input.value = '';
      await post('message', {session: historySession, text});
      // Best-effort delivery (typed into the host terminal, same as the macOS composer) —
      // no confirmed echo, so the sent text only reappears once the transcript picks it up.
      await loadHistory();
    }
    function readFileAsDataURL(file) {
      return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
    }
    async function sendChatImage(input) {
      const file = input.files && input.files[0];
      if (!file || !historySession) return;
      const attachBtn = document.querySelector('.composer .attach');
      attachBtn.disabled = true;
      attachBtn.textContent = '…';
      try {
        const dataURL = await readFileAsDataURL(file);
        const comma = dataURL.indexOf(',');
        const base64 = dataURL.slice(comma + 1);
        await post('image', {session: historySession, data: base64, mime: file.type});
        await loadHistory();
      } catch (e) {} finally {
        input.value = '';
        attachBtn.disabled = false;
        attachBtn.textContent = '📷';
      }
    }
    function blockHTML(b) {
      if (b.kind === 'text') return `<div class="blk text">${esc(b.text)}</div>`;
      if (b.kind === 'notice') return `<div class="blk notice">⚙ ${esc(b.text)}</div>`;
      if (b.kind === 'thinking') return `<div class="blk thinking">💭 ${esc(b.text)}</div>`;
      if (b.kind === 'toolUse') return `<div class="blk tool">→ ${esc(b.name)}` +
        (b.detail ? `: ${esc(b.detail)}` : '') + `</div>`;
      if (b.kind === 'toolResult') return `<div class="blk toolresult">${esc(b.text)}</div>`;
      return '';
    }
    function renderHistory(messages, unsupported) {
      const el = document.getElementById('historyBody'); // this is the scrolling element
      if (unsupported) {
        el.innerHTML = '<div class="empty">No chat history available for this agent.</div>';
        return;
      }
      if (!messages.length) {
        el.innerHTML = '<div class="empty">No messages yet.</div>';
        return;
      }
      const wasNearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
      el.innerHTML = messages.map(m =>
        `<div class="msg ${m.role}"><div class="bubble">${(m.blocks || []).map(blockHTML).join('')}` +
        (m.timestamp ? `<div class="time">${esc(timeLabel(m.timestamp))}</div>` : '') +
        `</div></div>`).join('');
      if (wasNearBottom) el.scrollTop = el.scrollHeight;
    }
    function render(sessions) {
      for (const s of sessions) sessionsById[s.session] = s;
      if (historySession) updateHistoryHeader();
      const root = document.getElementById('root');
      // Every poll would otherwise blow away the whole list's DOM, wiping out anything
      // typed into an open "Or type an answer…"/feedback box mid-edit — so skip the
      // rebuild while focus is inside one of those fields. The data above (sessionsById,
      // the chat header) still updates; only the destructive DOM replace is deferred.
      const active = document.activeElement;
      if (active && root.contains(active) &&
          (active.tagName === 'TEXTAREA' || active.tagName === 'INPUT')) {
        return;
      }
      if (!sessions.length) {
        root.className = 'empty';
        root.innerHTML = 'No sessions right now.';
        return;
      }
      root.className = '';
      root.innerHTML = sessions.map(sessionHTML).join('');
    }
    // Notify on a session newly needing attention, or newly finishing — never on first
    // load (nothing to compare against yet), so reopening the page doesn't replay history.
    function checkForNotifications(sessions, isFirstLoad) {
      for (const s of sessions) {
        const prior = seen[s.session];
        seen[s.session] = s.status;
        if (isFirstLoad || prior === s.status) continue;
        if (s.prompt) {
          notify(`${s.agent}: needs you`, s.lastMessage || s.statusLabel);
        } else if (s.status === 'done') {
          notify(`${s.agent}: finished`, s.title);
        }
      }
    }
    let firstLoad = true;
    async function decide(sid, d) { if (await post('decision', {session: sid, decision: d})) poll(); }
    async function answer(sid, text) { if (!text) return; if (await post('answer', {session: sid, text})) poll(); }
    async function plan(sid, feedback) { if (await post('plan', {session: sid, feedback})) poll(); }
    async function poll() {
      try {
        const r = await fetch(`/r/${token}/state`);
        if (r.status === 410) {
          const root = document.getElementById('root');
          root.className = 'empty';
          root.innerHTML = 'This link was disconnected on the Mac.';
          return;
        }
        const data = await r.json();
        const sessions = data.sessions || [];
        checkForNotifications(sessions, firstLoad);
        firstLoad = false;
        render(sessions);
        if (historySession) await loadHistory();
      } catch (e) {}
      setTimeout(poll, 2000);
    }
    updateBell();
    poll();
    </script>
    </body></html>
    """
}
