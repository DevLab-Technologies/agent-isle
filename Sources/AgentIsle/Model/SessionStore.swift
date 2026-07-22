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

    /// Transcript-detected questions the user has already answered, with when they did,
    /// keyed by session. The poller keeps seeing the pending `AskUserQuestion` in the JSONL
    /// until the agent records its response, so this stops it from resurfacing (and
    /// re-chiming) the same card in that window. Cleared once the transcript moves past the
    /// question, or once the grace window lapses (see `wasTranscriptQuestionAnswered`).
    private var answeredTranscriptQuestions: [UUID: (question: AgentQuestion, at: Date)] = [:]
    /// How long an answered transcript question stays suppressed before it may resurface
    /// (in case a best-effort answer never reached the agent). `var` so tests can adjust it.
    var answeredQuestionGrace: TimeInterval = 8

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
    ///
    /// Exit is idempotent: while a collapse is already scheduled, further "outside"
    /// reports are ignored rather than rescheduling it. This lets a caller poll the
    /// pointer (every frame) without the deadline being pushed back on every tick — which
    /// would otherwise mean the island never actually collapses.
    func setHovering(_ inside: Bool) {
        if inside {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            if !isHovering { isHovering = true }
        } else {
            guard isHovering, hoverCollapseWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.hoverCollapseWork = nil
                self?.isHovering = false
            }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    // MARK: - Attention auto-expand

    /// Whether a new attention event (permission/question) for `session` should auto-expand
    /// the island. With smart suppression on, the expand is skipped when the session's own
    /// terminal is already frontmost — the user is looking at that session, so popping the
    /// panel open would just get in the way (the sound cue and banner still fire).
    ///
    /// `frontmostBundleID` is injected so the decision is unit-testable without the live
    /// workspace; the caller passes `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`.
    func shouldAutoExpand(for session: AgentSession,
                          smartSuppression: Bool,
                          frontmostBundleID: String?) -> Bool {
        guard smartSuppression else { return true }
        guard let terminal = session.terminalBundleID, let frontmost = frontmostBundleID
        else { return true }   // unknown host → can't suppress, so surface it
        return terminal != frontmost
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
        bypassedSessions.remove(id)
        alwaysAllowed[id] = nil
        answeredTranscriptQuestions[id] = nil
        if id == openedSessionID { closeChat() }
    }

    func clearAll() {
        sessions.removeAll()
        bypassedSessions.removeAll()
        alwaysAllowed.removeAll()
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

    /// Sessions the user chose to "Bypass" — every later request auto-approves.
    private var bypassedSessions: Set<UUID> = []
    /// Per-session "Always Allow" signatures (see `PermissionRequest.allowKey`).
    private var alwaysAllowed: [UUID: Set<String>] = [:]

    /// Whether a freshly-arrived request should be auto-approved without a card, because
    /// the user previously chose Bypass for the session or Always-Allow for this signature.
    func isAutoAllowed(sessionID: UUID, key: String) -> Bool {
        bypassedSessions.contains(sessionID) || (alwaysAllowed[sessionID]?.contains(key) ?? false)
    }

    func resolvePermission(sessionID: UUID, decision: PermissionDecision) {
        // Remember the choice so future prompts in this session can auto-answer.
        // Note: `allowKey` is an exact tool+command signature, so "Always Allow" only
        // silences an identical request — e.g. the same Bash command with a different
        // cwd re-prompts. This is deliberately conservative rather than pattern-matching.
        if decision == .bypass { bypassedSessions.insert(sessionID) }
        if decision == .always, let key = sessions.first(where: { $0.id == sessionID })?.permission?.allowKey {
            alwaysAllowed[sessionID, default: []].insert(key)
        }
        let allow = decision != .deny
        update(id: sessionID) { s in
            s.permission = nil
            s.status = allow ? .working : .idle
            s.lastMessage = message(for: decision)
        }
        SoundPlayer.shared.play(allow ? .approve : .deny)
        EventServer.shared?.reply(sessionID: sessionID, decision: decision.wireValue)
    }

    private func message(for decision: PermissionDecision) -> String {
        switch decision {
        case .deny:      return "Denied by user"
        case .allowOnce: return "Approved — continuing"
        case .always:    return "Always allowing this action"
        case .bypass:    return "Bypassing approvals for this session"
        }
    }

    /// Send the user's answer (one option, several joined options, or free text) back
    /// to the waiting agent. Ignores empty answers so a stray submit can't resolve it.
    ///
    /// Delivery depends on how the question reached us. A hook-pushed question has a
    /// parked connection, so the answer replies straight to the blocked hook. A
    /// transcript-detected question (Desktop app / no reachable hook) has no such channel,
    /// so we type the answer into the session's host app — best-effort, the same terminal-
    /// driving transport as in-notch chat, and it may not land in the Desktop app.
    func answerQuestion(sessionID: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: "; ")
        let session = sessions.first { $0.id == sessionID }
        let viaTranscript = session?.question?.source == .transcript
        // Remember an answered transcript question so the poller doesn't resurface it
        // while the answer is in flight.
        if viaTranscript, let q = session?.question {
            noteAnsweredTranscriptQuestion(sessionID, q)
        }
        update(id: sessionID) { s in
            s.question = nil
            s.status = .working
            s.lastMessage = viaTranscript ? "Sent to \(s.terminal): \(oneLine)" : "You chose: \(oneLine)"
        }
        SoundPlayer.shared.play(.select)
        if viaTranscript, let session {
            sendError = nil
            // Deliver the flattened one-line form (MessageSender flattens too, but keep
            // what we typed identical to what we recorded as the session's last message).
            MessageSender.send(oneLine, to: session) { [weak self] result in
                if case .failure(let error) = result {
                    self?.sendError = error.userMessage
                    SoundPlayer.shared.play(.deny)
                }
            }
        } else {
            EventServer.shared?.reply(sessionID: sessionID, decision: trimmed)
        }
    }

    /// Record that the user answered a transcript-detected question, with the time it
    /// happened. Extracted so the poller-suppression logic is unit-testable without
    /// driving the real message transport.
    func noteAnsweredTranscriptQuestion(_ sessionID: UUID, _ question: AgentQuestion) {
        answeredTranscriptQuestions[sessionID] = (question, Date())
    }

    /// True if `question` is one the user answered for this session recently enough that
    /// the transcript may not reflect it yet — the poller uses this to avoid resurfacing
    /// (and re-chiming) it. The grace window is deliberately short: if delivery didn't
    /// actually land (best-effort typing into the Desktop app), the question resurfaces
    /// afterward so the user sees it's still waiting rather than silently swallowed.
    func wasTranscriptQuestionAnswered(_ sessionID: UUID, _ question: AgentQuestion) -> Bool {
        guard let marker = answeredTranscriptQuestions[sessionID], marker.question == question
        else { return false }
        return Date().timeIntervalSince(marker.at) < answeredQuestionGrace
    }

    /// Forget the answered-marker once the transcript's pending question changes or clears,
    /// so a genuinely new question later can surface again.
    func reconcileAnsweredQuestion(_ sessionID: UUID, current: AgentQuestion?) {
        if let marker = answeredTranscriptQuestions[sessionID], marker.question != current {
            answeredTranscriptQuestions[sessionID] = nil
        }
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
                advanceTasks(&s.tasks)   // complete the active task, start the next
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

    /// Mark the current in-progress task done and promote the next pending one, so the
    /// demo's progress meter creeps forward on each completed cycle.
    private func advanceTasks(_ tasks: inout TaskList) {
        guard !tasks.isEmpty else { return }
        if let active = tasks.items.firstIndex(where: { $0.state == .inProgress }) {
            tasks.items[active].state = .completed
        }
        if let next = tasks.items.firstIndex(where: { $0.state == .pending }) {
            tasks.items[next].state = .inProgress
        }
    }

    static func demoSessions() -> [AgentSession] {
        let now = Date()
        func tasks(_ items: [(String, AgentTask.State)]) -> TaskList {
            TaskList(items: items.enumerated().map { AgentTask(id: $0.offset, text: $0.element.0, state: $0.element.1) })
        }
        return [
            AgentSession(agent: .claude, title: "island · vibe-clone", terminal: "iTerm",
                         lastMessage: "Wiring the task list into the session card",
                         status: .working, startedAt: now.addingTimeInterval(-1620),
                         updatedAt: now,
                         tasks: tasks([
                            ("Scaffold SwiftPM macOS app + notch panel", .completed),
                            ("Build Dynamic Island SwiftUI view", .completed),
                            ("Parse Claude transcripts for live status", .completed),
                            ("Render the agent task list in each card", .inProgress),
                            ("Add progress meter and overflow collapse", .pending),
                            ("Polish typography and spacing", .pending),
                         ]),
                         model: "Opus 4.8"),
            AgentSession(agent: .codex, title: "backend server", terminal: "Terminal",
                         lastMessage: "Building the REST endpoints",
                         status: .working, startedAt: now.addingTimeInterval(-3600),
                         updatedAt: now.addingTimeInterval(-40),
                         tasks: tasks([
                            ("Design the schema", .completed),
                            ("Implement /auth endpoints", .inProgress),
                            ("Add integration tests", .pending),
                         ]),
                         model: "GPT-5.6 Codex"),
            AgentSession(agent: .gemini, title: "optimize queries", terminal: "Ghostty",
                         lastMessage: "Analyzing the slow queries",
                         status: .working, startedAt: now.addingTimeInterval(-18000),
                         updatedAt: now.addingTimeInterval(-80),
                         model: "Gemini 2.5 Pro"),
            AgentSession(agent: .cursor, title: "refactor ui", terminal: "VS Code",
                         lastMessage: "Waiting for input",
                         status: .idle, startedAt: now.addingTimeInterval(-600),
                         updatedAt: now.addingTimeInterval(-120))
        ]
    }
}
