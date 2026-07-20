import SwiftUI
import Combine

/// Central state for all monitored agent sessions.
///
/// Sessions arrive from two sources:
///  1. The local `EventServer`, which real agents (Claude Code hooks, etc.) POST to.
///  2. The built-in demo generator, so the island looks alive before anything is wired up.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var isExpanded: Bool = false
    @Published var demoMode: Bool = false

    /// Whether the pointer is currently over the island. Driven by a window-level
    /// `NSEvent` monitor (see `NotchWindow`) rather than SwiftUI's `.onHover`, whose
    /// mouse-exit tracking is unreliable at the top screen edge and would leave the
    /// island stuck open.
    @Published private(set) var isHovering: Bool = false
    private var hoverCollapseWork: DispatchWorkItem?

    /// Current rendered size of the island, reported by SwiftUI so the window can
    /// shrink to fit — otherwise a full-screen panel would eat clicks everywhere.
    @Published var islandSize: CGSize = CGSize(width: 520, height: 64)

    /// Which sessions the expanded list shows (the footer tabs).
    @Published var filter: SessionFilter = .all

    // MARK: - Live chat

    /// The session whose full conversation is currently open, or nil for the list view.
    @Published var openedSessionID: UUID?
    /// Parsed messages for the open session, kept live by the tailer.
    @Published var openedMessages: [ChatMessage] = []
    /// True while the first read of an opened transcript is in flight.
    @Published var chatLoading: Bool = false
    /// Transient error surfaced after a failed send (e.g. missing permission).
    @Published var sendError: String?

    /// While a chat is open the panel stays pinned (won't auto-collapse on hover-out).
    var isPinned: Bool { openedSessionID != nil }

    var openedSession: AgentSession? {
        guard let id = openedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    private lazy var tailer = TranscriptTailer { [weak self] msgs in
        self?.openedMessages = msgs
        self?.chatLoading = false
    }
    /// Transcript currently being tailed, so we only (re)start when it actually changes.
    private var tailedURL: URL?

    private var demoTimer: Timer?

    // MARK: - Derived state

    /// Sessions ordered by how much they need attention.
    var orderedSessions: [AgentSession] {
        sessions.sorted { a, b in
            if a.status.priority != b.status.priority {
                return a.status.priority < b.status.priority
            }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Sessions shown in the list, honoring the current footer filter.
    var visibleSessions: [AgentSession] {
        orderedSessions.filter { filter.matches($0) }
    }

    /// The session the collapsed island should surface first.
    var focusSession: AgentSession? {
        orderedSessions.first
    }

    var attentionCount: Int {
        sessions.filter { $0.status == .waiting || $0.status == .asking }.count
    }

    var workingCount: Int {
        sessions.filter { $0.status == .working }.count
    }

    /// Report whether the pointer is inside the island. Entry applies immediately;
    /// exit is debounced slightly so brief tracking drops near the notch don't flicker.
    func setHovering(_ inside: Bool) {
        hoverCollapseWork?.cancel()
        hoverCollapseWork = nil
        if inside {
            if !isHovering { isHovering = true }
        } else {
            guard isHovering else { return }
            let work = DispatchWorkItem { [weak self] in self?.isHovering = false }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    // MARK: - Mutation

    func upsert(_ session: AgentSession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
    }

    func update(id: UUID, _ transform: (inout AgentSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[idx]
        transform(&s)
        s.updatedAt = Date()
        sessions[idx] = s
        // If the open session just gained (or changed) its transcript, start tailing it —
        // a hook-created row may appear before the watcher fills in the transcript path.
        if id == openedSessionID { ensureTailing(s) }
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        if id == openedSessionID { closeChat() }
    }

    func clearAll() {
        sessions.removeAll()
        if openedSessionID != nil { closeChat() }
    }

    // MARK: - Chat open/close

    /// Open a session's full conversation and start tailing its transcript live.
    func openChat(_ session: AgentSession) {
        if session.status == .done { acknowledge(sessionID: session.id) }
        openedSessionID = session.id
        // No need to touch isExpanded: a chat is only opened from the already-expanded
        // list, and `isPinned` keeps the panel open while it's up. Setting isExpanded
        // here would stick it open and defeat hover-driven auto-collapse after closing.
        openedMessages = []
        chatLoading = false
        sendError = nil
        tailedURL = nil
        ensureTailing(session)   // flips chatLoading back on if there's a transcript to read
    }

    func closeChat() {
        tailer.stop()
        openedSessionID = nil
        openedMessages = []
        chatLoading = false
        sendError = nil
        tailedURL = nil
    }

    /// Start (or switch) the tailer if the session has a transcript we aren't already
    /// following. Sessions without a transcript (e.g. external agents) show a notice.
    private func ensureTailing(_ session: AgentSession) {
        guard let url = session.transcriptURL, url != tailedURL else { return }
        tailedURL = url
        chatLoading = true
        tailer.start(url: url, agent: session.agent)
    }

    /// Deliver a typed message into the session's terminal.
    func sendMessage(_ text: String, to session: AgentSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendError = nil
        MessageSender.send(trimmed, to: session) { [weak self] result in
            switch result {
            case .success:
                SoundPlayer.shared.play(.select)
            case .failure(let error):
                self?.sendError = error.userMessage
                SoundPlayer.shared.play(.deny)
            }
        }
    }

    // MARK: - Permission decisions

    func resolvePermission(sessionID: UUID, allow: Bool) {
        update(id: sessionID) { s in
            s.permission = nil
            s.status = allow ? .working : .idle
            s.lastMessage = allow ? "Approved — continuing" : "Denied by user"
        }
        SoundPlayer.shared.play(allow ? .approve : .deny)
        EventServer.shared?.reply(sessionID: sessionID, decision: allow ? "allow" : "deny")
    }

    func answerQuestion(sessionID: UUID, option: String) {
        update(id: sessionID) { s in
            s.question = nil
            s.status = .working
            s.lastMessage = "You chose: \(option)"
        }
        SoundPlayer.shared.play(.select)
        EventServer.shared?.reply(sessionID: sessionID, decision: option)
    }

    func acknowledge(sessionID: UUID) {
        update(id: sessionID) { s in
            s.status = .idle
        }
    }

    // MARK: - Demo mode

    func startDemo() {
        demoMode = true
        sessions = SessionStore.demoSessions()
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDemo() }
        }
    }

    func stopDemo() {
        demoMode = false
        demoTimer?.invalidate()
        demoTimer = nil
        // Remove the demo sessions; the watcher repopulates real ones on its next tick.
        clearAll()
    }

    private var demoStep = 0
    private func tickDemo() {
        demoStep += 1
        guard let claude = sessions.first(where: { $0.agent == .claude }) else { return }

        // Cycle Claude through a realistic loop: working -> permission -> approved -> done.
        switch demoStep % 5 {
        case 1:
            update(id: claude.id) { s in
                s.status = .working
                s.lastMessage = "Reading src/auth/middleware.ts"
            }
        case 2:
            update(id: claude.id) { s in
                s.status = .waiting
                s.lastMessage = "Wants to edit middleware.ts"
                s.permission = PermissionRequest(
                    toolName: "Edit",
                    filePath: "src/auth/middleware.ts",
                    diffAdded: 3, diffRemoved: 1,
                    previewLines: [
                        DiffLine(kind: .context, lineNumber: 12, text: "const verify = (token) =>"),
                        DiffLine(kind: .removed, lineNumber: 13, text: "  jwt.verify(token);"),
                        DiffLine(kind: .added, lineNumber: 13, text: "  if (!token) throw new"),
                        DiffLine(kind: .added, lineNumber: 14, text: "   AuthError('missing');"),
                        DiffLine(kind: .added, lineNumber: 15, text: "  return jwt.verify(token,")
                    ])
            }
            SoundPlayer.shared.play(.attention)
        case 3:
            // If the user didn't act, auto-continue the demo.
            if sessions.first(where: { $0.id == claude.id })?.status == .waiting {
                update(id: claude.id) { s in
                    s.permission = nil
                    s.status = .working
                    s.lastMessage = "Editing middleware.ts (+3 -1)"
                }
            }
        case 4:
            update(id: claude.id) { s in
                s.status = .asking
                s.lastMessage = "Which deployment target?"
                s.question = AgentQuestion(prompt: "Which deployment target?",
                                           options: ["Production", "Staging", "Local only"])
            }
            SoundPlayer.shared.play(.attention)
        default:
            update(id: claude.id) { s in
                s.question = nil
                s.status = .done
                s.lastMessage = "Done — click to jump"
            }
            SoundPlayer.shared.play(.done)
        }

        // Nudge the other agents so they feel live too.
        if let gemini = sessions.first(where: { $0.agent == .gemini }) {
            update(id: gemini.id) { s in
                s.lastMessage = demoStep % 2 == 0 ? "Analyzing slow queries" : "Updated src/db/queries.ts (+8 -23)"
            }
        }
    }

    static func demoSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(agent: .claude, title: "fix auth bug", terminal: "iTerm",
                         lastMessage: "Let me look at the auth module",
                         status: .working, startedAt: now.addingTimeInterval(-1620)),
            AgentSession(agent: .codex, title: "backend server", terminal: "Terminal",
                         lastMessage: "Building the REST endpoints",
                         status: .working, startedAt: now.addingTimeInterval(-3600)),
            AgentSession(agent: .gemini, title: "optimize queries", terminal: "Ghostty",
                         lastMessage: "Analyzing the slow queries",
                         status: .working, startedAt: now.addingTimeInterval(-18000)),
            AgentSession(agent: .cursor, title: "refactor ui", terminal: "VS Code",
                         lastMessage: "Waiting for input",
                         status: .idle, startedAt: now.addingTimeInterval(-600))
        ]
    }
}
