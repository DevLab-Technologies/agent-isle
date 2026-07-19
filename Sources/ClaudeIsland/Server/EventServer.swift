import Foundation
import Network

/// A minimal localhost HTTP server that real agents push events to.
///
/// Claude Code (and any other tool) can POST a small JSON payload to
/// `http://localhost:4711/event` from a hook. Two kinds of requests exist:
///
///  - Fire-and-forget updates (status/message changes) → respond immediately.
///  - Blocking permission/question requests → the connection is parked until the
///    user decides in the island, then the server responds with the decision.
///    This lets a Claude Code `PreToolUse` hook gate a tool on the notch answer.
@MainActor
final class EventServer {
    static var shared: EventServer?
    static let port: UInt16 = 4711

    private let store: SessionStore
    private var listener: NWListener?

    /// Connections waiting on a user decision, keyed by session id.
    private var pending: [UUID: (connection: NWConnection, kind: String)] = [:]

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: EventServer.port)!)
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("EventServer failed: \(error)")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in self?.receive(on: conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("EventServer listening on localhost:\(EventServer.port)")
        } catch {
            NSLog("EventServer could not start: \(error)")
        }
    }

    // MARK: - Request handling

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in self.handleRequest(data, on: conn) }
            } else if isComplete || error != nil {
                conn.cancel()
            }
        }
    }

    private func handleRequest(_ data: Data, on conn: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            respond(on: conn, json: #"{"ok":false}"#); return
        }
        // Split HTTP headers from the body.
        guard let range = request.range(of: "\r\n\r\n") else {
            respond(on: conn, json: #"{"ok":true}"#); return
        }
        let body = String(request[range.upperBound...])
        guard let bodyData = body.data(using: .utf8),
              let event = try? JSONDecoder().decode(AgentEvent.self, from: bodyData) else {
            respond(on: conn, json: #"{"ok":false,"error":"bad json"}"#); return
        }
        process(event, on: conn)
    }

    private func process(_ event: AgentEvent, on conn: NWConnection) {
        // Turn off demo mode the first time a real event arrives.
        if store.demoMode { store.stopDemo(); store.clearAll() }

        let sessionID = event.stableID
        let agent = AgentKind(rawValue: event.agent ?? "unknown") ?? .unknown

        switch event.type {
        case "status", "update":
            let status = SessionStatus(rawValue: event.status ?? "working") ?? .working
            upsertSession(id: sessionID, agent: agent, event: event, status: status)
            respond(on: conn, json: #"{"ok":true}"#)

        case "permission":
            var request = PermissionRequest(toolName: event.tool ?? "Tool",
                                            filePath: event.file,
                                            command: event.command,
                                            diffAdded: event.added ?? 0,
                                            diffRemoved: event.removed ?? 0)
            request.previewLines = (event.diff ?? []).map { $0.toDiffLine() }
            // Attach to the session the scanner already tracks, if present, so we
            // decorate the existing row instead of creating a duplicate.
            if store.sessions.contains(where: { $0.id == sessionID }) {
                store.update(id: sessionID) { s in
                    s.status = .waiting
                    s.permission = request
                    if let m = event.message { s.lastMessage = m }
                    if let term = event.terminal { s.terminal = term }
                    if let bundle = event.term_bundle { s.terminalBundleID = bundle }
                }
            } else {
                store.upsert(sessionFor(id: sessionID, agent: agent, event: event,
                                        status: .waiting, permission: request))
            }
            SoundPlayer.shared.play(.attention)
            pending[sessionID] = (conn, "permission")   // hold the connection open

        case "question":
            let q = AgentQuestion(prompt: event.prompt ?? "Choose an option",
                                  options: event.options ?? ["Yes", "No"])
            if store.sessions.contains(where: { $0.id == sessionID }) {
                store.update(id: sessionID) { s in
                    s.status = .asking
                    s.question = q
                }
            } else {
                store.upsert(sessionFor(id: sessionID, agent: agent, event: event,
                                        status: .asking, question: q))
            }
            SoundPlayer.shared.play(.attention)
            pending[sessionID] = (conn, "question")

        case "done":
            upsertSession(id: sessionID, agent: agent, event: event, status: .done)
            SoundPlayer.shared.play(.done)
            respond(on: conn, json: #"{"ok":true}"#)

        case "remove":
            store.remove(id: sessionID)
            respond(on: conn, json: #"{"ok":true}"#)

        default:
            respond(on: conn, json: #"{"ok":true}"#)
        }
    }

    private func upsertSession(id: UUID, agent: AgentKind, event: AgentEvent, status: SessionStatus) {
        if store.sessions.contains(where: { $0.id == id }) {
            store.update(id: id) { s in
                s.status = status
                if let msg = event.message { s.lastMessage = msg }
                if let title = event.title { s.title = title }
                // The hook knows the real host terminal from TERM_PROGRAM — trust it.
                if let term = event.terminal { s.terminal = term }
                if let bundle = event.term_bundle { s.terminalBundleID = bundle }
            }
        } else {
            store.upsert(sessionFor(id: id, agent: agent, event: event, status: status))
        }
    }

    private func sessionFor(id: UUID, agent: AgentKind, event: AgentEvent,
                            status: SessionStatus,
                            permission: PermissionRequest? = nil,
                            question: AgentQuestion? = nil) -> AgentSession {
        AgentSession(id: id,
                     agent: agent,
                     title: event.title ?? "session",
                     terminal: event.terminal ?? "Terminal",
                     lastMessage: event.message ?? status.label,
                     status: status,
                     permission: permission,
                     question: question,
                     terminalBundleID: event.term_bundle)
    }

    // MARK: - Replies back to a blocked hook

    /// Called by the store when the user decides; unblocks the parked connection.
    func reply(sessionID: UUID, decision: String) {
        guard let (conn, _) = pending.removeValue(forKey: sessionID) else { return }
        let json = "{\"ok\":true,\"decision\":\"\(decision)\"}"
        respond(on: conn, json: json)
    }

    private func respond(on conn: NWConnection, json: String) {
        let body = json.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var out = header.data(using: .utf8) ?? Data()
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Wire format

/// JSON payload agents POST to `/event`.
struct AgentEvent: Decodable {
    var type: String                 // status | permission | question | done | remove
    var session: String?             // caller-supplied stable id (e.g. Claude session_id)
    var agent: String?               // claude | codex | gemini ...
    var title: String?
    var terminal: String?
    var term_bundle: String?         // host app bundle id for precise Jump
    var message: String?
    var status: String?              // working | waiting | idle ...

    // permission fields
    var tool: String?
    var file: String?
    var command: String?
    var added: Int?
    var removed: Int?
    var diff: [WireDiffLine]?

    // question fields
    var prompt: String?
    var options: [String]?

    /// Deterministic UUID from the caller's session string so repeat events map to one row.
    var stableID: UUID {
        guard let session else { return UUID() }
        return UUID.deterministic(from: session)
    }
}

struct WireDiffLine: Decodable {
    var kind: String     // added | removed | context
    var line: Int?
    var text: String

    func toDiffLine() -> DiffLine {
        let k: DiffLine.Kind
        switch kind {
        case "added": k = .added
        case "removed": k = .removed
        default: k = .context
        }
        return DiffLine(kind: k, lineNumber: line, text: text)
    }
}

extension UUID {
    /// Stable UUID derived from an arbitrary string (FNV-1a seeded).
    static func deterministic(from string: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        var h = hash
        for i in 0..<8 { bytes[i] = UInt8((h >> (UInt64(i) * 8)) & 0xff) }
        h = hash &* 0x2545F4914F6CDD1D
        for i in 0..<8 { bytes[8 + i] = UInt8((h >> (UInt64(i) * 8)) & 0xff) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
