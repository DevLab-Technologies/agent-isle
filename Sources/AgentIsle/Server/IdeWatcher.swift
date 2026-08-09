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

    /// Surface a session whose transcript changed within this window. Driven by the
    /// user-configurable idle-cleanup preference (minutes), read live each scan so a change
    /// takes effect without a restart.
    private var activeWindow: TimeInterval { AppSettings.shared.idleCleanupMinutes * 60 }
    /// Treat a session as actively working if its transcript changed this recently.
    private let workingWindow: TimeInterval = 15
    /// A hook-free session is only reported "done" once its transcript has been quiet this
    /// long — well past `workingWindow`, so a brief mid-turn pause doesn't fire a false
    /// completion. Balances notification latency against noise.
    private let settledWindow: TimeInterval = 45
    /// Never show more than this many sessions at once.
    private let maxSessions = 10
    /// Cap on SSH sessions surfaced from Desktop's store, matching the per-agent cap used
    /// for the other hook-free adapters.
    private let maxRemoteSessions = 5

    private var trackedIDs: Set<UUID> = []
    /// Sessions we've already posted a "done" notification for during their current quiet
    /// period; cleared when the session resumes working, so each completion notifies once.
    private var doneNotified: Set<UUID> = []
    /// Cache of token totals keyed by session id, invalidated when the file changes.
    private var tokenCache: [String: (mtime: Date, tokens: Int)] = [:]
    /// Sessions whose token total is being recomputed off-main, so we don't queue a
    /// second read for the same file before the first lands.
    private var tokenInFlight: Set<String> = []
    /// Cache of sub-agent task/activity keyed by agent id, so each poll re-reads a
    /// sub-agent file only when it actually changed. Pruned to live agents each scan.
    private var subAgentCache: [String: TranscriptReader.SubAgentCache] = [:]

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
        var liveSubAgentIDs: Set<String> = []
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
            let terminal = source.label
            let tokens = tokens(for: c)

            // Background sub-agents live in `<session-id>/subagents/*.jsonl`. A session
            // waiting on them has a quiet transcript of its own, so treat it as working
            // while any sub-agent is active — otherwise it looks idle mid-orchestration.
            let subDir = c.url.deletingPathExtension().appendingPathComponent("subagents")
            let subs = TranscriptReader.subAgents(inDir: subDir,
                                                  activeWindow: activeWindow,
                                                  workingWindow: workingWindow,
                                                  cache: &subAgentCache)
            liveSubAgentIDs.formUnion(subs.map(\.id))
            let working = Date().timeIntervalSince(c.mtime) < workingWindow
                || subs.contains { $0.working }

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
                    // Host label. Claude Desktop is the exception: it fires the hook for
                    // tools but reports no TERM_PROGRAM, so the hook mislabels it "Terminal"
                    // (and pins a bundle, so the rule below would keep that stale label). The
                    // transcript's `entrypoint` names Desktop exactly, so it wins there — the
                    // card then reads "Answer in Desktop" and Jumper deep-links to the exact
                    // session. For editors/terminals the hook is more precise (it tells VS Code
                    // from Cursor, iTerm from Terminal), so keep it when we have it.
                    if activity.entrypoint == "claude-desktop" {
                        s.terminal = terminal          // "Desktop"
                        s.terminalBundleID = nil       // let Jumper resolve via the deep-link
                    } else if s.terminalBundleID == nil {
                        s.terminal = terminal
                    }
                    s.tokens = tokens
                    // Only update the model when this tail actually carried one; a chunk
                    // without an assistant turn shouldn't wipe a model we already know.
                    if let model = activity.model { s.model = model }
                    s.workspacePath = activity.cwd
                    s.transcriptURL = c.url
                    // Only replace tasks when this scan actually found a TodoWrite; a tail
                    // that no longer contains one shouldn't wipe a list we already have.
                    if !activity.tasks.isEmpty { s.tasks = TaskList(items: activity.tasks) }
                    s.subAgents = subs

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
                if newlySurfaced {
                    SoundPlayer.shared.play(.attention)
                    if let surfaced = store.sessions.first(where: { $0.id == id }) {
                        VoiceAnnouncer.shared.announce(session: surfaced, kind: .question)
                    }
                }
                // A hook-free session has no explicit "done" event; its turn finishing shows
                // up as the transcript going quiet. Only notify once it's been quiet past
                // `settledWindow` (not the moment it goes idle), so a brief mid-turn pause
                // doesn't fire a false completion. Reset when it resumes so each turn's
                // completion notifies exactly once.
                if working {
                    doneNotified.remove(id)
                } else if Date().timeIntervalSince(c.mtime) >= settledWindow,
                          !doneNotified.contains(id),
                          let finished = store.sessions.first(where: { $0.id == id }),
                          finished.status == .idle {
                    doneNotified.insert(id)
                    Notifier.shared.notifyDone(session: finished, title: finished.title)
                    VoiceAnnouncer.shared.announce(session: finished, kind: .done)
                }
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
                    subAgents: subs,
                    workspacePath: activity.cwd,
                    transcriptURL: c.url))
                if transcriptQuestion != nil {
                    SoundPlayer.shared.play(.attention)
                    if let surfaced = store.sessions.first(where: { $0.id == id }) {
                        VoiceAnnouncer.shared.announce(session: surfaced, kind: .question)
                    }
                }
            }
        }
        // Forget cached sub-agents that are no longer active, so the cache can't grow
        // without bound as sub-agents come and go. (Cache is tiny — at most
        // maxSessions × the per-session cap — so filtering every scan is cheap.)
        subAgentCache = subAgentCache.filter { liveSubAgentIDs.contains($0.key) }
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

        // Claude Code sessions running over SSH. Their transcript lives on the remote host,
        // so the poll above can't see them — Desktop's session store is the only local
        // record. Keyed by CLI session id, the same as a transcript-discovered session, so
        // a session Desktop later mirrors into `projects/ssh-<id>/` is already in `found`
        // here and keeps its richer transcript-derived card instead of being overwritten.
        for r in RemoteSessions.scan(activeWindow: activeWindow, limit: maxRemoteSessions)
        where !found.contains(r.id) {
            found.insert(r.id)
            trackedIDs.insert(r.id)
            let working = Date().timeIntervalSince(r.updatedAt) < workingWindow
            let lastMessage = r.host.map { "SSH · \($0)" } ?? "Remote session"
            if store.sessions.contains(where: { $0.id == r.id }) {
                store.update(id: r.id) { s in
                    s.title = r.title
                    s.lastMessage = lastMessage
                    if let model = r.model { s.model = model }
                    s.workspacePath = r.cwd
                    s.status = working ? .working : .idle
                    s.updatedAt = r.updatedAt
                }
            } else {
                if store.demoMode { store.stopDemo(); store.clearAll() }
                store.upsert(AgentSession(
                    id: r.id, agent: .claude, title: r.title, terminal: "Desktop",
                    lastMessage: lastMessage, status: working ? .working : .idle,
                    startedAt: r.startedAt, updatedAt: r.updatedAt, model: r.model,
                    workspacePath: r.cwd, cliSessionID: r.cliSessionID))
            }
        }

        pruneMissing(current: found)
        // Forget completion state for sessions that are no longer live, so a session id
        // reappearing later can notify again.
        doneNotified.formIntersection(found)
    }

    /// Last-known token total for a session, cached by transcript modification time. When
    /// the file has changed, the recount (a multi-MB read + JSON parse) runs off the main
    /// thread and updates the session when it lands — so the 2s scan never blocks the UI on
    /// a large, actively-growing transcript. The stale (or zero) value is shown until then.
    private func tokens(for c: Candidate) -> Int {
        if let cached = tokenCache[c.sessionID], cached.mtime == c.mtime {
            return cached.tokens
        }
        refreshTokens(for: c)
        return tokenCache[c.sessionID]?.tokens ?? 0
    }

    private func refreshTokens(for c: Candidate) {
        guard !tokenInFlight.contains(c.sessionID) else { return }
        tokenInFlight.insert(c.sessionID)
        let (url, sessionID, mtime) = (c.url, c.sessionID, c.mtime)
        let id = UUID.deterministic(from: sessionID)
        DispatchQueue.global(qos: .utility).async {
            let total = TranscriptReader.sessionTokens(in: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tokenCache[sessionID] = (mtime, total)
                self.tokenInFlight.remove(sessionID)
                if self.store.sessions.contains(where: { $0.id == id }) {
                    self.store.update(id: id) { $0.tokens = total }
                }
            }
        }
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
