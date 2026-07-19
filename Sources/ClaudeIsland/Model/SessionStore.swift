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
    @Published var demoMode: Bool = true

    /// Current rendered size of the island, reported by SwiftUI so the window can
    /// shrink to fit — otherwise a full-screen panel would eat clicks everywhere.
    @Published var islandSize: CGSize = CGSize(width: 520, height: 64)

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
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    func clearAll() {
        sessions.removeAll()
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
            Task { @MainActor in self?.tickDemo() }
        }
    }

    func stopDemo() {
        demoMode = false
        demoTimer?.invalidate()
        demoTimer = nil
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
