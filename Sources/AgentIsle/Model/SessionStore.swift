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

    /// Sessions the user dismissed from the island by hand (see `archive(id:)`). Excluded
    /// from `visibleSessions` so a finished session can be cleared without waiting for it to
    /// age out. Distinct from filter-hiding: archiving is a one-off user action, and an id is
    /// dropped from the set the moment its session becomes active again.
    @Published private(set) var archivedIDs: Set<UUID> = []

    /// Whether the pointer is currently over the island. Driven by a window-level
    /// `NSEvent` monitor (see `NotchWindow`) rather than SwiftUI's `.onHover`, whose
    /// mouse-exit tracking is unreliable at the top screen edge and would leave the
    /// island stuck open.
    @Published private(set) var isHovering: Bool = false
    /// Whether hover should currently expand the panel. Distinct from `isHovering` (the raw
    /// pointer state that drives the exit poll): it layers the user's hover-expand delay and
    /// auto-collapse dwell on top, so the panel doesn't pop the instant the pointer grazes
    /// the notch and can linger briefly after the pointer leaves. Views read this, not
    /// `isHovering`, to decide whether hover has opened the island.
    @Published private(set) var hoverExpanded: Bool = false
    private var hoverCollapseWork: DispatchWorkItem?
    private var hoverExpandedWork: DispatchWorkItem?

    /// Current rendered size of the island, reported by SwiftUI so the window can
    /// shrink to fit — otherwise a full-screen panel would eat clicks everywhere.
    @Published var islandSize: CGSize = CGSize(width: 520, height: 64)

    /// How far the rendered island is shifted from the window's center line. The collapsed
    /// pill sizes each ear to its own content and then slides itself so the notch gap stays
    /// on the notch; the click-through rect has to follow, or hover and taps drift off it.
    /// Zero for the expanded panel, which is symmetric.
    @Published var islandOffsetX: CGFloat = 0

    // MARK: - Live chat

    /// The session whose full conversation is currently open, or nil for the list view.
    @Published var openedSessionID: UUID?
    /// Parsed messages for the open session, kept live by the tailer.
    @Published var openedMessages: [ChatMessage] = []
    /// True while the first read of an opened transcript is in flight.
    @Published var chatLoading: Bool = false
    /// A failed send, kept per-session (rather than on `AgentSession` itself) since the
    /// transcript poller rewrites `lastMessage` every couple of seconds, which would wipe a
    /// failure written there almost immediately.
    struct SendErrorInfo {
        let message: String
        /// Whether the chat view should offer a button into Accessibility settings. We never
        /// open System Settings on our own — see `AccessibilityPermission` — so this is the
        /// user's way there.
        let needsAccessibility: Bool
        /// When this was reported — lets `sendError(for:)` prefer the newest failure across
        /// kinds without a separate "most recent kind" side table to keep in sync by hand.
        let reportedAt: Date
    }
    /// Transient errors surfaced after a failed send, one per (session, kind) — so a
    /// different kind starting or completing its own attempt can never discard another
    /// kind's still-unaddressed error; each kind only ever touches its own entry.
    @Published private var sendErrors: [SendAttemptKey: SendErrorInfo] = [:]
    /// The failed-send notice to show for `sessionID`, if any — read by `SessionRow`/
    /// `SessionChatView`. Only one notice fits in the UI, so this picks the most recently
    /// reported kind by `reportedAt`; an error not shown here isn't lost — it resurfaces once
    /// whichever is currently shown gets cleared.
    func sendError(for sessionID: UUID) -> SendErrorInfo? {
        SendKind.allCases
            .compactMap { sendErrors[SendAttemptKey(sessionID: sessionID, kind: $0)] }
            .max { $0.reportedAt < $1.reportedAt }
    }

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

    /// Sessions the user should actually see: `orderedSessions` minus anything a filter rule
    /// (or the probe/worker preset) hides, minus anything the user archived by hand. Every
    /// surface reads this rather than `sessions` so hidden and archived sessions drop out of
    /// the list, the pill, and the counts alike.
    var visibleSessions: [AgentSession] {
        orderedSessions.filter { !AppSettings.shared.isHidden($0) && !archivedIDs.contains($0.id) }
    }

    /// How many sessions are currently filtered out — surfaced as "+N hidden" so nothing is
    /// silently dropped. Counts only filter-hidden sessions; archived ones are a deliberate
    /// user dismissal, not a filtered-away session, so they're excluded from this count.
    var hiddenCount: Int {
        orderedSessions.filter { AppSettings.shared.isHidden($0) && !archivedIDs.contains($0.id) }.count
    }

    /// The session the collapsed island should surface first.
    var focusSession: AgentSession? {
        visibleSessions.first
    }

    var attentionCount: Int {
        visibleSessions.filter { $0.status == .waiting || $0.status == .asking || $0.status == .planning }.count
    }

    var workingCount: Int {
        visibleSessions.filter { $0.status == .working }.count
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
            if !isHovering {
                isHovering = true
                // Expand after the configured dwell (0 = immediate, the prior behavior).
                scheduleHoverExpanded(true, after: AppSettings.shared.hoverExpandDelay)
            }
        } else {
            guard isHovering, hoverCollapseWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverCollapseWork = nil
                self.isHovering = false
                // Linger the configured dwell before actually collapsing (0 = immediate).
                self.scheduleHoverExpanded(false, after: AppSettings.shared.autoCollapseDelay)
            }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    /// Transition `hoverExpanded` to `value` after `delay` seconds, cancelling any pending
    /// transition so a re-entry during the collapse dwell (or an exit during the expand
    /// delay) wins. A zero delay applies on the next runloop tick.
    private func scheduleHoverExpanded(_ value: Bool, after delay: TimeInterval) {
        hoverExpandedWork?.cancel()
        hoverExpandedWork = nil
        guard hoverExpanded != value else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hoverExpandedWork = nil
            self?.hoverExpanded = value
        }
        hoverExpandedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
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
        clearArchiveIfActive(id: session.id, status: session.status)
    }

    func update(id: UUID, _ transform: (inout AgentSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[idx]
        let previousStatus = s.status
        transform(&s)
        s.updatedAt = Date()
        sessions[idx] = s
        // A session that has just wrapped up shouldn't keep showing a failed-send banner for
        // whatever it was last trying to deliver — that attempt is moot now. Gated on a real
        // transition INTO `.done` (not `.idle`, and not a repeat of the same status): pollers
        // like `IdeWatcher` re-assert `.idle` on every scan tick, and unrelated actions (e.g.
        // denying a permission prompt) also land on `.idle` — neither means "this session's
        // send attempt is over," so clearing on those would wipe an unrelated, still-
        // unaddressed error. Sessions that never reach `.done` (hook-free ones tracked purely
        // by transcript activity, or ones whose parked prompt is abandoned — see
        // `EventServer.abandon`) don't get auto-cleared here; `archive(id:)`/`remove(id:)` are
        // the user's own way to dismiss a banner that outlives its relevance.
        if s.status == .done && previousStatus != .done {
            clearAllSendErrors(for: id)
        }
        // An archived session that starts working (or needs attention) again should
        // resurface rather than stay dismissed forever.
        clearArchiveIfActive(id: id, status: s.status)
        // If the open session just gained (or changed) its transcript, start tailing it —
        // a hook-created row may appear before the watcher fills in the transcript path.
        if id == openedSessionID { ensureTailing(s) }
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        bypassedSessions.remove(id)
        alwaysAllowed[id] = nil
        answeredTranscriptQuestions[id] = nil
        archivedIDs.remove(id)
        clearAllSendErrors(for: id)
        if id == openedSessionID { closeChat() }
    }

    /// Clear every outstanding send-error entry and `MessageSender` channel for `sessionID` —
    /// the single choke point for "this session's pending sends are moot now," so `sendErrors`
    /// and `MessageSender`'s per-channel state can't drift out of sync one call site at a time.
    /// Called on removal, archival, and a genuine transition to `.done` (see `update(id:_:)`).
    func clearAllSendErrors(for sessionID: UUID) {
        for kind in SendKind.allCases {
            let key = SendAttemptKey(sessionID: sessionID, kind: kind)
            sendErrors[key] = nil
            MessageSender.forgetChannel(key)
        }
    }

    func clearAll() {
        sessions.removeAll()
        bypassedSessions.removeAll()
        alwaysAllowed.removeAll()
        archivedIDs.removeAll()
        sendErrors.removeAll()
        MessageSender.forgetAllChannels()
        if openedSessionID != nil { closeChat() }
    }

    // MARK: - Archiving

    /// Dismiss a session from the island by hand — it drops out of `visibleSessions`
    /// immediately without waiting to age out. Most useful on a `.done` row. The session
    /// resurfaces if it becomes active again (see `clearArchiveIfActive`), so any outstanding
    /// send-error banner is cleared now — otherwise a stale one would resurface unchanged
    /// alongside it, describing an attempt the user already dismissed.
    func archive(id: UUID) {
        archivedIDs.insert(id)
        clearAllSendErrors(for: id)
        if id == openedSessionID { closeChat() }
    }

    /// Bring every archived session back into view.
    func unarchiveAll() {
        archivedIDs.removeAll()
    }

    /// Drop an id from the archived set once its session transitions back to an active,
    /// attention-worthy state, so a re-appearing session isn't kept hidden forever.
    private func clearArchiveIfActive(id: UUID, status: SessionStatus) {
        guard !archivedIDs.isEmpty else { return }
        switch status {
        case .working, .waiting, .asking, .planning:
            archivedIDs.remove(id)
        case .done, .idle:
            break
        }
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
        // Scoped to .message, the only kind tied to the chat input bar: .question/.plan
        // errors surface on their own cards regardless of whether chat is open.
        clearSendError(for: session.id, ifKind: .message)
        tailedURL = nil
        ensureTailing(session)   // flips chatLoading back on if there's a transcript to read
    }

    func closeChat() {
        tailer.stop()
        if let id = openedSessionID { clearSendError(for: id, ifKind: .message) }
        openedSessionID = nil
        openedMessages = []
        chatLoading = false
        tailedURL = nil
    }

    /// Force the island back to its collapsed state, regardless of *why* it was expanded.
    /// A plain `isExpanded = false` isn't enough: the panel also stays open while a chat
    /// is pinned (`isPinned`) or while hover-expand is latched (`hoverExpanded`), so a tap
    /// that only cleared `isExpanded` would appear to do nothing — the "stuck expanded"
    /// case. This clears every source and cancels the pending hover transitions so it
    /// won't immediately re-open until the pointer leaves and returns.
    func forceCollapse() {
        if openedSessionID != nil { closeChat() }
        isExpanded = false
        hoverExpandedWork?.cancel()
        hoverExpandedWork = nil
        hoverExpanded = false
    }

    /// Start (or switch) the tailer if the session has a transcript we aren't already
    /// following. Sessions without a transcript (e.g. external agents) show a notice.
    private func ensureTailing(_ session: AgentSession) {
        guard let url = session.transcriptURL, url != tailedURL else { return }
        tailedURL = url
        chatLoading = true
        tailer.start(url: url, agent: session.agent)
    }

    /// Surface a failed send once, in one place: the message plus whether the chat view
    /// should offer the Accessibility settings shortcut. Only ever touches `kind`'s own entry.
    func report(_ error: MessageSender.SendError, sessionID: UUID, kind: SendKind) {
        sendErrors[SendAttemptKey(sessionID: sessionID, kind: kind)] =
            SendErrorInfo(message: error.userMessage, needsAccessibility: isAccessibilityDenied(error),
                          reportedAt: Date())
        SoundPlayer.shared.play(.deny)
    }

    private func isAccessibilityDenied(_ error: MessageSender.SendError) -> Bool {
        if case .accessibilityDenied = error { return true }
        return false
    }

    /// Dismiss `kind`'s error for `sessionID` — called before starting a new attempt of that
    /// kind, or once a prior failure of that kind is no longer relevant (chat closed, a new
    /// prompt of that kind superseded it) — so it can optimistically clear its own stale error
    /// without touching any other kind's entry.
    func clearSendError(for sessionID: UUID, ifKind kind: SendKind) {
        sendErrors[SendAttemptKey(sessionID: sessionID, kind: kind)] = nil
    }

    /// The three independent channels that deliver text into a session's host. Two of these
    /// names echo `AgentSession.question`/`.plan` (the per-session cards they answer), which
    /// is intentional — `.message` has no such counterpart since chat input isn't gated by a
    /// pending card. The echo is only a naming convenience, not an enforced link: this enum is
    /// SessionStore's own bookkeeping for "what kind of send is in flight," kept separate from
    /// the session model.
    enum SendKind: Hashable, CaseIterable {
        case message, question, plan
    }

    /// Identifies one (session, kind) send channel, passed to `MessageSender` so *it* can
    /// guard against a stale, superseded completion — see `MessageSender.send(_:to:channel:)`.
    /// Cancellation of an outdated in-flight send is that module's job: whoever asks it to
    /// deliver text on a channel should get exactly one outcome, for the most recent request.
    struct SendAttemptKey: Hashable {
        let sessionID: UUID
        let kind: SendKind
    }

    /// Deliver `text` into `session`'s host via `MessageSender`, on the channel identified by
    /// `(session.id, kind)`. `onSuccess` runs only for the most recent attempt on that channel.
    private func deliver(_ text: String, to session: AgentSession, kind: SendKind,
                          onSuccess: (() -> Void)? = nil) {
        let sessionID = session.id
        clearSendError(for: sessionID, ifKind: kind)
        let channel = SendAttemptKey(sessionID: sessionID, kind: kind)
        MessageSender.send(text, to: session, channel: channel) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                onSuccess?()
            case .failure(let error):
                self.report(error, sessionID: sessionID, kind: kind)
            }
        }
    }

    /// Deliver a typed message into the session's host.
    ///
    /// Editor extensions (VS Code / Cursor / Windsurf) render their own input and can't be
    /// driven by synthetic keystrokes, so we use the extension's deep-link to open the exact
    /// session with the message pre-filled (one keypress to send) — no Accessibility needed.
    /// Terminals still take the keystroke/AppleScript transport.
    func sendMessage(_ text: String, to session: AgentSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Scoped to .message: the editor deep-link path below returns before `deliver` would
        // otherwise clear it, and a message attempt must never clear a different kind's
        // still-unaddressed error.
        clearSendError(for: session.id, ifKind: .message)

        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        if let url = Jumper.editorAnswerURL(for: session, prompt: oneLine) {
            NSWorkspace.shared.open(url)
            SoundPlayer.shared.play(.select)
            return
        }

        deliver(trimmed, to: session, kind: .message) {
            SoundPlayer.shared.play(.select)
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
        // Note: `allowKey` is an exact tool+command and/or tool+path signature, so
        // "Always Allow" only silences an identical request — e.g. the same Bash
        // command with a different cwd, or Edit of a different file, re-prompts.
        // This is deliberately conservative rather than pattern-matching.
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
    /// Delivery depends on how the question reached us:
    ///  - A hook-pushed question has a parked connection, so the answer replies straight to
    ///    the blocked hook (terminal CLI — fully automatic).
    ///  - An editor-extension question (VS Code / Cursor / Windsurf) has no hook and a native
    ///    picker we can't drive, but the extension deep-links to a session by id with the
    ///    answer pre-filled — so we open the exact conversation with the answer typed in and
    ///    leave the user one keypress. We can't confirm the send, so the card stays until the
    ///    poller sees the transcript advance.
    ///  - Any other transcript host (e.g. Desktop) has no channel, so we type the answer into
    ///    the host app — best-effort, and it may not land.
    func answerQuestion(sessionID: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: "; ")
        let session = sessions.first { $0.id == sessionID }
        // Mirrors `resolvePlan`'s `guard session?.plan != nil`: a second, near-simultaneous
        // call for the same question (double-click, double Return) must no-op once the first
        // call has already cleared it, rather than re-delivering and double-counting whatever
        // side effects `deliver` triggers.
        guard session?.question != nil else { return }
        let viaTranscript = session?.question?.source == .transcript

        // Editor extension: jump to the *exact* session via its deep-link (this is the only
        // thing that reliably works across multiple windows/tabs). The answer is passed as a
        // prompt too, but the extension only pre-fills it when the session isn't already open —
        // for a live/open session it shows "enter it manually", so we don't claim it was sent.
        // Leave the card up; the poller clears it once the transcript advances.
        if viaTranscript, let session, let url = Jumper.editorAnswerURL(for: session, prompt: oneLine) {
            NSWorkspace.shared.open(url)
            update(id: sessionID) { $0.lastMessage = "Opened in \($0.terminal) — answer it there" }
            SoundPlayer.shared.play(.select)
            return
        }

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
            // Deliver the flattened one-line form (MessageSender flattens too, but keep
            // what we typed identical to what we recorded as the session's last message).
            // `deliver` clears this session's .question error itself before attempting.
            deliver(oneLine, to: session, kind: .question)
        } else {
            EventServer.shared?.reply(sessionID: sessionID, decision: trimmed)
        }
    }

    // MARK: - Plan review

    /// Approve the plan the agent presented — let it proceed as written.
    func approvePlan(sessionID: UUID) {
        resolvePlan(sessionID: sessionID, feedback: nil)
    }

    /// Send the user's feedback on the plan back to the agent so it can revise.
    /// Empty feedback is treated as an approval so a stray submit still resolves cleanly.
    func sendPlanFeedback(sessionID: UUID, feedback: String) {
        resolvePlan(sessionID: sessionID, feedback: feedback)
    }

    /// Resolve a plan card: approve (nil/empty feedback) or send feedback for a revision.
    ///
    /// Delivery mirrors `answerQuestion`. A hook-pushed plan has a parked connection, so the
    /// decision replies straight to the blocked hook ("approve" for an approval, otherwise the
    /// feedback text). A transcript-detected plan has no such channel, so the reply is typed
    /// into the session's host app — best-effort, the same transport as in-notch chat.
    private func resolvePlan(sessionID: UUID, feedback: String?) {
        let session = sessions.first { $0.id == sessionID }
        guard session?.plan != nil else { return }
        let viaTranscript = session?.plan?.source == .transcript
        let trimmed = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFeedback = !trimmed.isEmpty
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: "; ")

        update(id: sessionID) { s in
            s.plan = nil
            s.status = .working
            s.lastMessage = hasFeedback
                ? (viaTranscript ? "Sent plan feedback to \(s.terminal)" : "Plan feedback: \(oneLine)")
                : "Plan approved"
        }
        SoundPlayer.shared.play(hasFeedback ? .select : .approve)

        if viaTranscript, let session {
            // `deliver` clears this session's .plan error itself before attempting.
            let text = hasFeedback ? oneLine : "Approved — proceed with the plan."
            deliver(text, to: session, kind: .plan)
        } else {
            // "approve" is the sentinel the hook maps to allow; anything else is feedback
            // that denies ExitPlanMode with the text as the reason so the agent revises.
            EventServer.shared?.reply(sessionID: sessionID, decision: hasFeedback ? oneLine : "approve")
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

        // Cycle Claude through a realistic loop: working -> permission -> question ->
        // plan review -> done.
        switch demoStep % 6 {
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
        case 5:
            update(id: claude.id) { s in
                s.question = nil
                s.status = .planning
                s.lastMessage = "Shared a plan for review"
                s.plan = AgentPlan(markdown: SessionStore.demoPlanMarkdown)
            }
            SoundPlayer.shared.play(.attention)
        default:
            update(id: claude.id) { s in
                s.question = nil
                s.plan = nil
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

    /// A representative plan (headings, lists, inline code, emphasis) so Demo Mode
    /// exercises the Markdown rendering in `PlanReviewCard`.
    static let demoPlanMarkdown = """
    ## Refactor the auth middleware

    Split the monolithic `verify()` into focused steps and add explicit error handling.

    ### Changes
    1. Extract `parseToken()` from `middleware.ts`
    2. Add an `AuthError` type with a *typed* reason
    3. Guard against a missing or expired token **before** calling `jwt.verify`

    ### Follow-ups
    - Cover the new paths with unit tests
    - Update the `/auth` docs

    ```ts
    if (!token) throw new AuthError('missing');
    return jwt.verify(token, secret);
    ```
    """

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
