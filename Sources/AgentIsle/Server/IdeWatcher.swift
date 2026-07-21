import Foundation

/// Discovers active Claude Code sessions — terminal **and** IDE — with no hooks.
///
/// Every Claude Code session appends to a transcript at
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. We poll these, treat any
/// transcript touched recently as an active session, and read its tail to learn the
/// working directory, git branch, source (`entrypoint`) and latest activity line.
///
/// The `entrypoint` field tells us where the session runs:
///   `cli` → Terminal, `claude-vscode` → VS Code, `cursor` → Cursor, `claude-desktop` → Desktop.
@MainActor
final class IdeWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private let projectsDir: URL

    /// Surface a session whose transcript changed within this window.
    private let activeWindow: TimeInterval = 8 * 60
    /// Treat a session as actively working if its transcript changed this recently.
    private let workingWindow: TimeInterval = 15
    /// Never show more than this many sessions at once.
    private let maxSessions = 10

    private var trackedIDs: Set<UUID> = []
    /// Cache of token totals keyed by session id, invalidated when the file changes.
    private var tokenCache: [String: (mtime: Date, tokens: Int)] = [:]

    init(store: SessionStore) {
        self.store = store
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        self.projectsDir = base.appendingPathComponent("projects")
    }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Scan

    private struct Candidate {
        let url: URL
        let sessionID: String
        let mtime: Date
    }

    private func scan() {
        let candidates = activeTranscripts()
        guard !candidates.isEmpty else { pruneMissing(current: []); return }

        var found: Set<UUID> = []
        for c in candidates {
            let activity = TranscriptReader.latestActivity(in: c.url)
            let source = SessionSource(entrypoint: activity.entrypoint)
            guard source.include else { continue }

            // Same id scheme the EventServer uses (deterministic from the session id),
            // so a hook's permission attaches to this session instead of duplicating it.
            let id = UUID.deterministic(from: c.sessionID)
            found.insert(id)
            trackedIDs.insert(id)

            let title = displayTitle(activity: activity)
            let working = Date().timeIntervalSince(c.mtime) < workingWindow
            let terminal = source.label
            let tokens = tokens(for: c)

            // Drop the answered-marker once the transcript's pending question moves on, so
            // a genuinely new question can surface later.
            store.reconcileAnsweredQuestion(id, current: activity.question)

            if let existing = store.sessions.first(where: { $0.id == id }) {
                // A hook-pushed question owns its slot (it has a parked connection); never
                // let the poller override it. Otherwise surface a transcript question,
                // unless the user just answered this exact one (still lingering in the JSONL).
                let hookOwned = existing.question?.source == .hook
                let transcriptQuestion: AgentQuestion? = {
                    guard !hookOwned, let q = activity.question,
                          !store.wasTranscriptQuestionAnswered(id, q) else { return nil }
                    return q
                }()
                let newlySurfaced = transcriptQuestion != nil && existing.question != transcriptQuestion

                store.update(id: id) { s in
                    s.title = title
                    // Keep the hook's precise terminal (from TERM_PROGRAM) if we have it;
                    // the transcript only knows cli vs IDE, not which terminal app.
                    if s.terminalBundleID == nil { s.terminal = terminal }
                    s.tokens = tokens
                    // Only update the model when this tail actually carried one; a chunk
                    // without an assistant turn shouldn't wipe a model we already know.
                    if let model = activity.model { s.model = model }
                    s.workspacePath = activity.cwd
                    s.transcriptURL = c.url
                    // Only replace tasks when this scan actually found a TodoWrite; a tail
                    // that no longer contains one shouldn't wipe a list we already have.
                    if !activity.tasks.isEmpty { s.tasks = TaskList(items: activity.tasks) }

                    if hookOwned {
                        // The hook manages the question/permission lifecycle; just refresh activity.
                        s.lastMessage = activity.text
                    } else if let q = transcriptQuestion {
                        s.question = q
                        s.status = .asking
                        s.lastMessage = q.summary
                    } else {
                        // No live transcript question — clear a stale transcript-sourced one.
                        if s.question?.source == .transcript { s.question = nil }
                        s.lastMessage = activity.text
                        if s.permission == nil && s.question == nil {
                            s.status = working ? .working : .idle
                        }
                    }
                }
                if newlySurfaced { SoundPlayer.shared.play(.attention) }
            } else {
                if store.demoMode { store.stopDemo(); store.clearAll() }
                // A brand-new session nobody has pushed a hook question for: surface any
                // pending transcript question directly.
                let transcriptQuestion = activity.question
                store.upsert(AgentSession(
                    id: id,
                    agent: .claude,
                    title: title,
                    terminal: terminal,
                    lastMessage: transcriptQuestion?.summary ?? activity.text,
                    status: transcriptQuestion != nil ? .asking : (working ? .working : .idle),
                    startedAt: (try? c.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? c.mtime,
                    updatedAt: c.mtime,
                    question: transcriptQuestion,
                    tasks: TaskList(items: activity.tasks),
                    tokens: tokens,
                    model: activity.model,
                    workspacePath: activity.cwd,
                    transcriptURL: c.url))
                if transcriptQuestion != nil { SoundPlayer.shared.play(.attention) }
            }
        }
        // Other agents (Grok, Copilot, …) discovered from their own history files.
        for e in ExternalAgents.scanAll(activeWindow: activeWindow, maxPerAgent: 5) {
            found.insert(e.id)
            trackedIDs.insert(e.id)
            let working = Date().timeIntervalSince(e.mtime) < workingWindow
            if store.sessions.contains(where: { $0.id == e.id }) {
                store.update(id: e.id) { s in
                    s.title = e.title
                    s.lastMessage = e.lastMessage
                    if let model = e.model { s.model = model }
                    s.workspacePath = e.cwd
                    s.transcriptURL = e.historyURL
                    s.status = working ? .working : .idle
                }
            } else {
                if store.demoMode { store.stopDemo(); store.clearAll() }
                store.upsert(AgentSession(
                    id: e.id, agent: e.agent, title: e.title, terminal: e.terminal,
                    lastMessage: e.lastMessage, status: working ? .working : .idle,
                    startedAt: e.mtime, updatedAt: e.mtime, model: e.model, workspacePath: e.cwd,
                    transcriptURL: e.historyURL))
            }
        }

        pruneMissing(current: found)
    }

    /// Token total for a session, cached by transcript modification time.
    private func tokens(for c: Candidate) -> Int {
        if let cached = tokenCache[c.sessionID], cached.mtime == c.mtime {
            return cached.tokens
        }
        let total = TranscriptReader.sessionTokens(in: c.url)
        tokenCache[c.sessionID] = (c.mtime, total)
        return total
    }

    /// Every transcript touched within the active window (so concurrent sessions in the
    /// same repo each appear), most-recent first, capped at `maxSessions`.
    private func activeTranscripts() -> [Candidate] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        var candidates: [Candidate] = []
        let now = Date()
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(m) < activeWindow {
                    candidates.append(Candidate(url: url,
                                                sessionID: url.deletingPathExtension().lastPathComponent,
                                                mtime: m))
                }
            }
        }
        return Array(candidates.sorted { $0.mtime > $1.mtime }.prefix(maxSessions))
    }

    private func pruneMissing(current: Set<UUID>) {
        let gone = trackedIDs.subtracting(current)
        for id in gone where store.sessions.contains(where: { $0.id == id }) {
            store.remove(id: id)
        }
        trackedIDs = current
    }

    private func displayTitle(activity: TranscriptReader.Activity) -> String {
        let repo = activity.cwd.map { ($0 as NSString).lastPathComponent } ?? "session"
        if let b = activity.branch, !b.isEmpty, b != "HEAD" {
            return "\(repo) · \(b)"
        }
        return repo
    }
}

/// Maps a Claude Code `entrypoint` to a display label, and whether to surface it.
private struct SessionSource {
    let label: String
    let include: Bool

    init(entrypoint: String?) {
        switch entrypoint {
        case "cli":
            label = "Terminal"; include = true
        case "claude-vscode":
            label = "VS Code"; include = true
        case let e? where e.contains("cursor"):
            label = "Cursor"; include = true
        case let e? where e.contains("windsurf"):
            label = "Windsurf"; include = true
        case "claude-desktop":
            label = "Desktop"; include = true
        case .none:
            // No entrypoint recorded yet — assume a terminal session.
            label = "Terminal"; include = true
        default:
            label = "Agent"; include = true
        }
    }
}
