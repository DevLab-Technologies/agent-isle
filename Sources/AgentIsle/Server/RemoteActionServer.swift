import Foundation
import Network

/// One address the mobile page is reachable at, and the token-scoped URL to reach it.
struct RemoteAccessLink {
    struct Endpoint {
        let kind: NetworkInterfaces.Address.Kind
        let url: URL
    }
    let endpoints: [Endpoint]
    let expiresAt: Date
}

/// Serves a small mobile-facing page so a pending permission/question/plan prompt can be
/// approved from a phone — over the LAN or over Tailscale — without any external backend.
///
/// Unlike `EventServer` (deliberately pinned to `127.0.0.1`), this listener binds every
/// interface: reachability from another device is the whole point. Tailscale needs no
/// special handling here — once connected it just presents as another interface with an
/// IP in `100.64.0.0/10`, which `NetworkInterfaces` already detects, so the same listener
/// serves both the LAN and Tailscale paths.
///
/// The security boundary is the per-prompt token instead of the network binding: a random,
/// single-use, short-TTL token minted only when the user taps "Approve from phone", scoped
/// to one session's current prompt, and covering nothing else (three fixed routes, no
/// listing endpoint). Off until first use — nothing listens until that first tap.
@MainActor
final class RemoteActionServer {
    static let shared = RemoteActionServer()

    static let port: UInt16 = 4712
    static let maxRequestSize = 16 * 1024
    private static let tokenTTL: TimeInterval = 10 * 60

    private var listener: NWListener?
    private weak var store: SessionStore?

    private struct TokenEntry {
        let sessionID: UUID
        let expiresAt: Date
    }
    private var tokens: [String: TokenEntry] = [:]

    private init() {}

    func attach(to store: SessionStore) {
        self.store = store
    }

    /// Mint a token for `sessionID`'s current prompt and return the URLs it's reachable
    /// at. Starts the listener on first call; returns nil if it can't start or no
    /// interface (LAN/Tailscale) is reachable.
    func issueLink(sessionID: UUID) -> RemoteAccessLink? {
        guard store != nil else { return nil }
        if listener == nil { start() }
        guard listener != nil else { return nil }

        let addresses = NetworkInterfaces.reachableAddresses()
        guard !addresses.isEmpty else { return nil }

        purgeExpired()
        let token = Self.randomToken()
        let expiresAt = Date().addingTimeInterval(Self.tokenTTL)
        tokens[token] = TokenEntry(sessionID: sessionID, expiresAt: expiresAt)

        let endpoints = addresses.compactMap { addr -> RemoteAccessLink.Endpoint? in
            guard let url = URL(string: "http://\(addr.host):\(Self.port)/r/\(token)") else { return nil }
            return RemoteAccessLink.Endpoint(kind: addr.kind, url: url)
        }
        guard !endpoints.isEmpty else { return nil }
        return RemoteAccessLink(endpoints: endpoints, expiresAt: expiresAt)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func purgeExpired() {
        let now = Date()
        tokens = tokens.filter { $0.value.expiresAt > now }
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
                conn.start(queue: .main)
                Task { @MainActor [weak self] in self?.receive(on: conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("RemoteActionServer listening on :\(Self.port)")
        } catch {
            NSLog("RemoteActionServer could not start: \(error)")
        }
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

                    switch HTTPFraming.requestLength(in: buffer, maxRequestSize: Self.maxRequestSize) {
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
        // /r/<token>[/decision|/answer|/plan|/state]
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 2, segments[0] == "r" else { respondNotFound(conn); return }
        let token = segments[1]
        let action = segments.count >= 3 ? segments[2] : nil

        purgeExpired()
        guard let entry = tokens[token] else { respondGone(conn); return }
        let body = HTTPFraming.body(of: data)

        switch (method, action) {
        case ("GET", nil):
            respondHTML(conn)
        case ("GET", "state"):
            respondState(conn, token: token, sessionID: entry.sessionID)
        case ("POST", "decision"):
            handleDecision(body: body, token: token, sessionID: entry.sessionID, conn: conn)
        case ("POST", "answer"):
            handleAnswer(body: body, token: token, sessionID: entry.sessionID, conn: conn)
        case ("POST", "plan"):
            handlePlan(body: body, token: token, sessionID: entry.sessionID, conn: conn)
        default:
            respondNotFound(conn)
        }
    }

    // MARK: - Actions

    private func handleDecision(body: Data, token: String, sessionID: UUID, conn: NWConnection) {
        guard let store,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let decision = obj["decision"] as? String else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.permission != nil else {
            respondGone(conn); return
        }
        // The phone offers only the two least-consequential decisions — never
        // "Always"/"Bypass" — so a leaked token can approve/deny one call, not grant
        // standing auto-approval for the session. Fails closed: anything but an exact
        // "allow" denies, matching `EventServer.reply`'s own fail-closed fallback.
        store.resolvePermission(sessionID: sessionID, decision: decision == "allow" ? .allowOnce : .deny)
        tokens.removeValue(forKey: token)
        respondJSON(conn, ["ok": true])
    }

    private func handleAnswer(body: Data, token: String, sessionID: UUID, conn: NWConnection) {
        guard let store,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = obj["text"] as? String else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.question != nil else {
            respondGone(conn); return
        }
        store.answerQuestion(sessionID: sessionID, answer: text)
        tokens.removeValue(forKey: token)
        respondJSON(conn, ["ok": true])
    }

    private func handlePlan(body: Data, token: String, sessionID: UUID, conn: NWConnection) {
        guard let store else { respondBadRequest(conn); return }
        guard store.sessions.first(where: { $0.id == sessionID })?.plan != nil else {
            respondGone(conn); return
        }
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let feedback = ((obj?["feedback"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if feedback.isEmpty {
            store.approvePlan(sessionID: sessionID)
        } else {
            store.sendPlanFeedback(sessionID: sessionID, feedback: feedback)
        }
        tokens.removeValue(forKey: token)
        respondJSON(conn, ["ok": true])
    }

    private func respondState(_ conn: NWConnection, token: String, sessionID: UUID) {
        guard let store, let session = store.sessions.first(where: { $0.id == sessionID }) else {
            tokens.removeValue(forKey: token)
            respondJSON(conn, ["resolved": true]); return
        }
        if let p = session.permission {
            var obj: [String: Any] = ["kind": "permission", "tool": p.toolName]
            if let command = p.command { obj["command"] = command }
            if let path = p.filePath { obj["path"] = path }
            respondJSON(conn, obj)
        } else if let q = session.question {
            let parts = q.parts.map { part -> [String: Any] in
                ["header": part.header, "prompt": part.prompt, "options": part.options,
                 "multiSelect": part.multiSelect, "allowsOther": part.allowsOther]
            }
            respondJSON(conn, ["kind": "question", "parts": parts])
        } else if let plan = session.plan {
            respondJSON(conn, ["kind": "plan", "markdown": plan.markdown])
        } else {
            tokens.removeValue(forKey: token)
            respondJSON(conn, ["resolved": true])
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
    /// Polls `/r/<token>/state` and posts back to `/r/<token>/{decision,answer,plan}`.
    private static let pageHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Agent Isle</title>
    <style>
      :root { color-scheme: dark; }
      body { font-family: -apple-system, system-ui, sans-serif; background:#0b0b0d; color:#eee;
             margin:0; padding:20px; }
      h1 { font-size:13px; opacity:.5; text-transform:uppercase; letter-spacing:.08em; margin:0 0 14px; }
      .card { background:#17171a; border-radius:12px; padding:16px; margin-bottom:12px; }
      .tool { color:#f5b74d; font-weight:600; margin-bottom:6px; }
      pre { white-space:pre-wrap; word-break:break-word; background:#000; padding:10px;
            border-radius:8px; font-size:13px; margin:6px 0 0; }
      button { display:block; width:100%; padding:14px; margin:8px 0 0; border:none;
               border-radius:10px; font-size:16px; font-weight:600; }
      .allow { background:#5cd48c; color:#000; }
      .deny { background:#f36b6b; color:#000; }
      .opt { background:#26262b; color:#eee; text-align:left; }
      textarea { width:100%; box-sizing:border-box; background:#000; color:#eee;
                 border:1px solid #333; border-radius:8px; padding:10px; font-size:15px; margin-top:8px; }
      .done, .empty { text-align:center; opacity:.6; padding:40px 0; }
    </style></head><body>
    <h1>Agent Isle</h1>
    <div id="root" class="empty">Loading…</div>
    <script>
    const token = location.pathname.split('/')[2];
    let done = false;
    function esc(s) { return (s||'').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
    async function post(path, body) {
      try {
        const r = await fetch(`/r/${token}/${path}`, {
          method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body || {})
        });
        return r.ok;
      } catch (e) { return false; }
    }
    function render(state) {
      const root = document.getElementById('root');
      if (state.resolved) {
        root.className = 'done';
        root.innerHTML = 'Resolved on the Mac.';
        done = true;
        return;
      }
      root.className = '';
      if (state.kind === 'permission') {
        root.innerHTML =
          `<div class="card"><div class="tool">${esc(state.tool)}</div>` +
          (state.path ? `<div>${esc(state.path)}</div>` : '') +
          (state.command ? `<pre>${esc(state.command)}</pre>` : '') +
          `</div><button class="allow" onclick="decide('allow')">Allow Once</button>` +
          `<button class="deny" onclick="decide('deny')">Deny</button>`;
      } else if (state.kind === 'question') {
        const p = state.parts[0];
        const opts = p.options.map(o =>
          `<button class="opt" onclick='answer(${JSON.stringify(o)})'>${esc(o)}</button>`).join('');
        root.innerHTML = `<div class="card">${esc(p.prompt)}</div>${opts}` +
          (p.allowsOther
            ? `<textarea id="other" placeholder="Or type an answer…"></textarea>` +
              `<button class="opt" onclick="answer(document.getElementById('other').value)">Send</button>`
            : '');
      } else if (state.kind === 'plan') {
        root.innerHTML =
          `<div class="card"><pre>${esc(state.markdown)}</pre></div>` +
          `<button class="allow" onclick="plan('')">Approve</button>` +
          `<textarea id="fb" placeholder="Or send feedback…"></textarea>` +
          `<button class="opt" onclick="plan(document.getElementById('fb').value)">Send Feedback</button>`;
      }
    }
    async function decide(d) { if (await post('decision', {decision: d})) poll(); }
    async function answer(text) { if (!text) return; if (await post('answer', {text})) poll(); }
    async function plan(feedback) { if (await post('plan', {feedback})) poll(); }
    async function poll() {
      if (done) return;
      try {
        const r = await fetch(`/r/${token}/state`);
        if (r.status === 410) { render({resolved: true}); return; }
        render(await r.json());
      } catch (e) {}
      if (!done) setTimeout(poll, 2000);
    }
    poll();
    </script>
    </body></html>
    """
}
