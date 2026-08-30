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
/// can't grant standing auto-approval for a session. Off until first use — nothing
/// listens until the first tap on "Connect phone".
@MainActor
final class RemoteActionServer {
    static let shared = RemoteActionServer()

    static let port: UInt16 = 4712
    static let maxRequestSize = 16 * 1024
    private static let tokenTTL: TimeInterval = 24 * 60 * 60

    private var listener: NWListener?
    private weak var store: SessionStore?
    private var activeToken: (token: String, expiresAt: Date)?

    private init() {}

    func attach(to store: SessionStore) {
        self.store = store
    }

    var isConnected: Bool {
        guard let activeToken else { return false }
        return activeToken.expiresAt > Date()
    }

    /// The current pairing link, minting one only if none is active (or the previous one
    /// expired) — reopening this popover shows the same link rather than silently
    /// invalidating whatever the phone already scanned. Starts the listener on first
    /// call; returns nil if it can't start or no interface (LAN/Tailscale) is reachable.
    func currentLink() -> RemoteAccessLink? {
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

    private func link(for token: String) -> RemoteAccessLink? {
        let addresses = NetworkInterfaces.reachableAddresses()
        guard !addresses.isEmpty else { return nil }
        let endpoints = addresses.compactMap { addr -> RemoteAccessLink.Endpoint? in
            guard let url = URL(string: "http://\(addr.host):\(Self.port)/r/\(token)") else { return nil }
            return RemoteAccessLink.Endpoint(kind: addr.kind, url: url)
        }
        return endpoints.isEmpty ? nil : RemoteAccessLink(endpoints: endpoints)
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
        // /r/<token>[/decision|/answer|/plan|/state]
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
        case ("POST", "decision"):
            handleDecision(body: body, conn: conn)
        case ("POST", "answer"):
            handleAnswer(body: body, conn: conn)
        case ("POST", "plan"):
            handlePlan(body: body, conn: conn)
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

    /// Every session across the store that currently has something to act on — the phone
    /// polls this rather than one session's state, since one pairing link covers all of
    /// them. A multi-part question only shows its first part, matching the simplification
    /// the demo/simple-producer path already makes for this wire format.
    private func respondState(_ conn: NWConnection) {
        guard let store else { respondJSON(conn, ["prompts": []]); return }
        let prompts: [[String: Any]] = store.sessions.compactMap { session in
            if let p = session.permission {
                var obj: [String: Any] = ["session": session.id.uuidString, "kind": "permission",
                                          "title": session.title, "agent": session.agent.displayName,
                                          "tool": p.toolName]
                if let command = p.command { obj["command"] = command }
                if let path = p.filePath { obj["path"] = path }
                return obj
            } else if let q = session.question, let part = q.parts.first {
                return ["session": session.id.uuidString, "kind": "question",
                       "title": session.title, "agent": session.agent.displayName,
                       "prompt": part.prompt, "options": part.options,
                       "allowsOther": part.allowsOther]
            } else if let plan = session.plan {
                return ["session": session.id.uuidString, "kind": "plan",
                       "title": session.title, "agent": session.agent.displayName,
                       "markdown": plan.markdown]
            }
            return nil
        }
        respondJSON(conn, ["prompts": prompts])
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
    /// Polls `/r/<token>/state` for the list of sessions with something pending, and posts
    /// back to `/r/<token>/{decision,answer,plan}` with an explicit `session` id.
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
      .head { font-size:11px; opacity:.55; margin-bottom:6px; }
      .agent { color:#f5b74d; font-weight:600; }
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
      .empty { text-align:center; opacity:.5; padding:60px 0; font-size:14px; }
    </style></head><body>
    <h1>Agent Isle</h1>
    <div id="root" class="empty">Loading…</div>
    <script>
    const token = location.pathname.split('/')[2];
    function esc(s) { return (s||'').replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
    async function post(path, body) {
      try {
        const r = await fetch(`/r/${token}/${path}`, {
          method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body || {})
        });
        return r.ok;
      } catch (e) { return false; }
    }
    function cardHTML(p) {
      const sid = p.session;
      const head = `<div class="head"><span class="agent">${esc(p.agent)}</span> · ${esc(p.title)}</div>`;
      if (p.kind === 'permission') {
        return `<div class="card">${head}<div class="tool">${esc(p.tool)}</div>` +
          (p.path ? `<div>${esc(p.path)}</div>` : '') +
          (p.command ? `<pre>${esc(p.command)}</pre>` : '') +
          `<button class="allow" onclick="decide('${sid}','allow')">Allow Once</button>` +
          `<button class="deny" onclick="decide('${sid}','deny')">Deny</button></div>`;
      }
      if (p.kind === 'question') {
        const opts = (p.options || []).map(o =>
          `<button class="opt" onclick='answer(\"${sid}\", ${JSON.stringify(o)})'>${esc(o)}</button>`).join('');
        return `<div class="card">${head}<div>${esc(p.prompt)}</div>${opts}` +
          (p.allowsOther
            ? `<textarea id="other-${sid}" placeholder="Or type an answer…"></textarea>` +
              `<button class="opt" onclick="answer('${sid}', document.getElementById('other-${sid}').value)">Send</button>`
            : '') + `</div>`;
      }
      if (p.kind === 'plan') {
        return `<div class="card">${head}<pre>${esc(p.markdown)}</pre>` +
          `<button class="allow" onclick="plan('${sid}','')">Approve</button>` +
          `<textarea id="fb-${sid}" placeholder="Or send feedback…"></textarea>` +
          `<button class="opt" onclick="plan('${sid}', document.getElementById('fb-${sid}').value)">Send Feedback</button></div>`;
      }
      return '';
    }
    function render(prompts) {
      const root = document.getElementById('root');
      if (!prompts.length) {
        root.className = 'empty';
        root.innerHTML = 'No pending approvals right now.';
        return;
      }
      root.className = '';
      root.innerHTML = prompts.map(cardHTML).join('');
    }
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
        render(data.prompts || []);
      } catch (e) {}
      setTimeout(poll, 2000);
    }
    poll();
    </script>
    </body></html>
    """
}
