import SwiftUI

/// Shared UI colors used outside the status enum.
enum Palette {
    static let deny = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let allow = Color(red: 0.36, green: 0.83, blue: 0.55)
}

/// The coding agent behind a session.
enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case cursor
    case grok
    case copilot
    case opencode
    case droid
    case kiro
    case amp
    case aider
    case cline
    case goose
    case qwen
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        case .droid: return "Droid"
        case .kiro: return "Kiro"
        case .amp: return "Amp"
        case .aider: return "Aider"
        case .cline: return "Cline"
        case .goose: return "Goose"
        case .qwen: return "Qwen"
        case .unknown: return "Agent"
        }
    }

    /// Accent color used for the agent's badge and status dot.
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.53, blue: 0.32) // Claude orange
        case .codex: return Color(red: 0.36, green: 0.83, blue: 0.55)  // green
        case .gemini: return Color(red: 0.42, green: 0.60, blue: 0.98) // blue
        case .cursor: return Color(red: 0.75, green: 0.75, blue: 0.80)
        case .grok: return Color(red: 0.12, green: 0.12, blue: 0.14)    // Grok near-black
        case .copilot: return Color(red: 0.60, green: 0.65, blue: 0.72) // Copilot gray-blue
        case .opencode: return Color(red: 0.94, green: 0.76, blue: 0.35)
        case .droid: return Color(red: 0.55, green: 0.78, blue: 0.98)
        case .kiro: return Color(red: 0.80, green: 0.52, blue: 0.96)
        case .amp: return Color(red: 0.98, green: 0.45, blue: 0.55)
        case .aider: return Color(red: 0.30, green: 0.72, blue: 0.66)  // teal
        case .cline: return Color(red: 0.42, green: 0.46, blue: 0.92)  // indigo
        case .goose: return Color(red: 0.66, green: 0.58, blue: 0.38)  // olive
        case .qwen: return Color(red: 0.60, green: 0.40, blue: 0.85)   // violet
        case .unknown: return Color.gray
        }
    }

    /// Single-glyph mark shown in the compact badge.
    var glyph: String {
        switch self {
        case .claude: return "✳"
        case .codex: return "⬡"
        case .gemini: return "◆"
        case .cursor: return "▸"
        case .grok: return "𝕏"
        case .copilot: return "⊚"
        case .opencode: return "◇"
        case .droid: return "◈"
        case .kiro: return "❖"
        case .amp: return "⚡"
        case .aider: return "✦"
        case .cline: return "◎"
        case .goose: return "⬢"
        case .qwen: return "❋"
        case .unknown: return "●"
        }
    }
}

/// What an agent session is currently doing.
enum SessionStatus: String, Codable {
    case working        // actively producing output
    case waiting        // needs a permission decision
    case asking         // asking the user a question
    case planning       // presented a plan awaiting review
    case done           // finished, waiting to be acknowledged
    case idle           // connected but quiet

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Permission"
        case .asking: return "Question"
        case .planning: return "Plan"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .working: return Color(red: 0.42, green: 0.60, blue: 0.98)
        case .waiting: return Color(red: 0.98, green: 0.72, blue: 0.30)
        case .asking: return Color(red: 0.70, green: 0.55, blue: 0.98)
        case .planning: return Color(red: 0.36, green: 0.78, blue: 0.82) // teal — plan review
        case .done: return Color(red: 0.36, green: 0.83, blue: 0.55)
        case .idle: return Color(white: 0.5)
        }
    }

    /// Ordering priority when picking which session the collapsed island shows.
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .asking: return 1
        case .planning: return 2
        case .working: return 3
        case .done: return 4
        case .idle: return 5
        }
    }
}

/// How the user resolved a permission request.
enum PermissionDecision {
    case deny         // block this one
    case allowOnce    // allow just this call
    case always       // allow this call, and auto-allow matching requests for the session
    case bypass       // allow this call, and auto-allow *everything* for the session

    /// What we echo back to the hook — Claude Code only understands allow/deny; the
    /// "always"/"bypass" memory lives on the Agent Isle side (auto-answering later prompts).
    var wireValue: String { self == .deny ? "deny" : "allow" }
}

/// A pending permission request (e.g. an edit or command the agent wants to run).
struct PermissionRequest: Identifiable, Equatable {
    let id: UUID
    var toolName: String        // "Edit", "Bash", "Write"...
    var filePath: String?       // affected path, if any
    var command: String?        // shell command, if any
    var diffAdded: Int
    var diffRemoved: Int
    var previewLines: [DiffLine]

    init(id: UUID = UUID(),
         toolName: String,
         filePath: String? = nil,
         command: String? = nil,
         diffAdded: Int = 0,
         diffRemoved: Int = 0,
         previewLines: [DiffLine] = []) {
        self.id = id
        self.toolName = toolName
        self.filePath = filePath
        self.command = command
        self.diffAdded = diffAdded
        self.diffRemoved = diffRemoved
        self.previewLines = previewLines
    }

    /// Signature used by "Always Allow": the tool, plus the command for Bash so remembering
    /// is per-command (a bare tool like Edit remembers the whole tool for the session).
    var allowKey: String { "\(toolName)|\(command ?? "")" }
}

struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    enum Kind { case context, added, removed }
    var kind: Kind
    var lineNumber: Int?
    var text: String
}

/// One question within an ask: a prompt and its selectable options.
struct QuestionPart: Equatable, Hashable, Identifiable {
    var id: Int                     // position in the ask; keys the card's per-part state
    var header: String              // short label, e.g. "Deploy target"
    var prompt: String              // full question text
    var options: [String]
    var multiSelect: Bool = false   // let the user pick more than one option
    var allowsOther: Bool = false   // offer a free-text "Other" field
}

/// A question the agent is asking. Holds one or more parts, answered together and
/// sent back in a single reply (matching how Claude's AskUserQuestion batches them).
struct AgentQuestion: Equatable, Hashable {
    /// How the question reached us — which decides how an answer is delivered back.
    enum Source: Equatable, Hashable {
        case hook        // pushed by the PreToolUse hook; answer replies on its parked connection
        case transcript  // discovered by polling the JSONL; answer is typed into the host app
    }

    var parts: [QuestionPart]
    var source: Source

    init(parts: [QuestionPart], source: Source = .hook) {
        self.parts = parts
        self.source = source
    }

    /// Convenience for a single-part question (demo mode / simple producers).
    init(prompt: String, options: [String],
         multiSelect: Bool = false, allowsOther: Bool = false, source: Source = .hook) {
        self.parts = [QuestionPart(id: 0, header: "", prompt: prompt, options: options,
                                   multiSelect: multiSelect, allowsOther: allowsOther)]
        self.source = source
    }

    /// Short one-line summary for compact surfaces (collapsed island / lastMessage).
    var summary: String {
        guard let first = parts.first else { return "Question" }
        return parts.count > 1 ? "\(parts.count) questions" : first.prompt
    }
}

/// A plan an agent presented for review (e.g. Claude Code's `ExitPlanMode`). The
/// markdown body is rendered as formatted text in the card; the user can approve it or
/// reply with feedback, both delivered back the same way an answered question is.
struct AgentPlan: Equatable, Hashable {
    /// How the plan reached us — which decides how approval/feedback is delivered back,
    /// mirroring `AgentQuestion.Source`.
    enum Source: Equatable, Hashable {
        case hook        // pushed by the PreToolUse hook; reply on its parked connection
        case transcript  // discovered by polling the JSONL; reply is typed into the host app
    }

    var markdown: String
    var source: Source

    init(markdown: String, source: Source = .hook) {
        self.markdown = markdown
        self.source = source
    }

    /// Short one-line summary for compact surfaces (collapsed island / lastMessage /
    /// notification). Takes the first heading or non-empty line, stripped of markdown marks.
    var summary: String {
        for raw in markdown.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let cleaned = line.drMarked
            if !cleaned.isEmpty { return cleaned }
        }
        return "Plan ready for review"
    }
}

private extension String {
    /// Strip common leading markdown marks (heading #, list bullets, blockquote) and inline
    /// emphasis/backtick characters so a line reads cleanly in a compact one-line surface.
    var drMarked: String {
        var s = self
        while let first = s.first, "#>-*+ ".contains(first) { s.removeFirst() }
        s.removeAll { $0 == "*" || $0 == "`" || $0 == "_" }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// One item in an agent's task/todo list (Claude Code's `TodoWrite`).
struct AgentTask: Identifiable, Equatable {
    enum State: String, Equatable {
        case pending        // not started yet — "open"
        case inProgress     // actively being worked
        case completed      // done

        /// Accent color for the checkbox and text.
        var color: Color {
            switch self {
            case .completed:  return SessionStatus.done.color
            case .inProgress: return SessionStatus.working.color
            case .pending:    return Color(white: 0.55)
            }
        }

        /// SF Symbol used for the leading checkbox.
        var symbol: String {
            switch self {
            case .completed:  return "checkmark.circle.fill"
            case .inProgress: return "circle.dotted"
            case .pending:    return "circle"
            }
        }
    }

    let id: Int         // position in the list (stable across re-reads of one TodoWrite)
    var text: String
    var state: State
}

/// A session's task list plus the derived counts shown in the summary line.
struct TaskList: Equatable {
    var items: [AgentTask]

    var isEmpty: Bool { items.isEmpty }
    var done: Int { items.filter { $0.state == .completed }.count }
    var inProgress: Int { items.filter { $0.state == .inProgress }.count }
    var open: Int { items.filter { $0.state == .pending }.count }
    var total: Int { items.count }

    /// Reordered for display: active work first, then still-open, then completed —
    /// so the most relevant items stay visible when the list is truncated.
    var ordered: [AgentTask] {
        func rank(_ s: AgentTask.State) -> Int {
            switch s {
            case .inProgress: return 0
            case .pending:    return 1
            case .completed:  return 2
            }
        }
        return items.enumerated()
            .sorted { a, b in
                let ra = rank(a.element.state), rb = rank(b.element.state)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

/// A background sub-agent spawned by a session (Claude Code's `Task` tool). Each runs in
/// its own `<session>/subagents/agent-*.jsonl` transcript while the parent waits, so its
/// progress is invisible on the parent's own transcript — we surface it here.
struct SubAgent: Identifiable, Equatable {
    let id: String          // agent file id (stable across re-reads)
    var title: String       // the task it was spawned with (first prompt line)
    var lastMessage: String // its latest activity line
    var working: Bool       // transcript changed very recently
    var updatedAt: Date
}

/// One piece of a chat message, rendered as its own block in the transcript view.
enum ChatBlock: Equatable {
    case text(String)
    case thinking(String)
    case toolUse(name: String, detail: String?)
    case toolResult(String)
}

/// A single turn in a session's conversation, parsed from the transcript.
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: String          // transcript entry uuid (stable across re-reads)
    var role: Role
    var blocks: [ChatBlock]
    var timestamp: Date?

    /// True when the message carries no visible content (e.g. an empty turn).
    var isEmpty: Bool { blocks.isEmpty }
}

/// One monitored agent session.
struct AgentSession: Identifiable, Equatable {
    let id: UUID
    var agent: AgentKind
    var title: String           // task / branch name, e.g. "fix auth bug"
    var terminal: String        // "iTerm", "Ghostty"...
    var lastMessage: String     // latest line of activity
    var status: SessionStatus
    var startedAt: Date
    var updatedAt: Date
    var permission: PermissionRequest?
    var question: AgentQuestion?
    var plan: AgentPlan?        // a plan awaiting the user's review (nil when none)
    var tasks: TaskList         // the agent's current todo list (empty when none)
    var tokens: Int             // total tokens used this session (0 if unknown)
    var model: String?          // display name of the current model, e.g. "Opus 4.8" (nil if unknown)
    var subAgents: [SubAgent]   // active background sub-agents it spawned (empty when none)
    var workspacePath: String?  // cwd, used by "Jump" to focus the session's app
    var terminalBundleID: String?  // real host app bundle id (from the hook's TERM_PROGRAM)
    var transcriptURL: URL?     // on-disk conversation file (Claude/Grok/Copilot), for the live chat view

    init(id: UUID = UUID(),
         agent: AgentKind,
         title: String,
         terminal: String,
         lastMessage: String,
         status: SessionStatus,
         startedAt: Date = Date(),
         updatedAt: Date = Date(),
         permission: PermissionRequest? = nil,
         question: AgentQuestion? = nil,
         plan: AgentPlan? = nil,
         tasks: TaskList = TaskList(items: []),
         tokens: Int = 0,
         model: String? = nil,
         subAgents: [SubAgent] = [],
         workspacePath: String? = nil,
         terminalBundleID: String? = nil,
         transcriptURL: URL? = nil) {
        self.workspacePath = workspacePath
        self.terminalBundleID = terminalBundleID
        self.transcriptURL = transcriptURL
        self.id = id
        self.agent = agent
        self.title = title
        self.terminal = terminal
        self.lastMessage = lastMessage
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.permission = permission
        self.question = question
        self.plan = plan
        self.tasks = tasks
        self.tokens = tokens
        self.model = model
        self.subAgents = subAgents
    }

    /// Compact human-readable token count, e.g. "48.2k" or "1.3M" (nil when unknown).
    var tokenText: String? {
        tokens > 0 ? formatTokens(tokens) : nil
    }

    /// Human-friendly elapsed time since the session started.
    var elapsedText: String {
        let s = Int(Date().timeIntervalSince(startedAt))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
