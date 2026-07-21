import SwiftUI

/// The footer tabs that filter the session list.
enum SessionFilter {
    case all        // Monitor — everything
    case approve    // Approve — sessions waiting on a permission
    case ask        // Ask — sessions asking a question

    func matches(_ s: AgentSession) -> Bool {
        switch self {
        case .all: return true
        case .approve: return s.status == .waiting
        case .ask: return s.status == .asking
        }
    }
}

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
        case .unknown: return "●"
        }
    }
}

/// What an agent session is currently doing.
enum SessionStatus: String, Codable {
    case working        // actively producing output
    case waiting        // needs a permission decision
    case asking         // asking the user a question
    case done           // finished, waiting to be acknowledged
    case idle           // connected but quiet

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Permission"
        case .asking: return "Question"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .working: return Color(red: 0.42, green: 0.60, blue: 0.98)
        case .waiting: return Color(red: 0.98, green: 0.72, blue: 0.30)
        case .asking: return Color(red: 0.70, green: 0.55, blue: 0.98)
        case .done: return Color(red: 0.36, green: 0.83, blue: 0.55)
        case .idle: return Color(white: 0.5)
        }
    }

    /// Ordering priority when picking which session the collapsed island shows.
    var priority: Int {
        switch self {
        case .waiting: return 0
        case .asking: return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        }
    }
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
}

struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    enum Kind { case context, added, removed }
    var kind: Kind
    var lineNumber: Int?
    var text: String
}

/// A question the agent is asking, with selectable options.
struct AgentQuestion: Equatable {
    var prompt: String
    var options: [String]
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
    var tasks: TaskList         // the agent's current todo list (empty when none)
    var tokens: Int             // total tokens used this session (0 if unknown)
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
         tasks: TaskList = TaskList(items: []),
         tokens: Int = 0,
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
        self.tasks = tasks
        self.tokens = tokens
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
