import Foundation

/// Reads the tail of a Claude Code `*.jsonl` transcript to derive a one-line summary
/// of what the session is currently doing, plus the active git branch.
enum TranscriptReader {
    struct Activity {
        var text: String
        var branch: String?
        var cwd: String?
        var entrypoint: String?
        var model: String?
        var tasks: [AgentTask] = []
        /// An unanswered `AskUserQuestion` found in the transcript, if any. Populated for
        /// sessions we only see via polling (Desktop app, or hosts the hook can't reach),
        /// so a question still surfaces even when no hook pushed it.
        var question: AgentQuestion? = nil
    }

    /// Generic tail reader: walk the last chunk of a JSONL file newest-first and return
    /// the first non-nil result of `transform`, condensed to one line.
    static func lastText(in url: URL, maxBytes: Int = 48 * 1024,
                         transform: ([String: Any]) -> String?) -> String? {
        let lines = tailLines(of: url, maxBytes: maxBytes)
        for raw in lines.reversed() {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let t = transform(obj), !t.isEmpty { return firstLine(t) }
        }
        return nil
    }

    /// The most recent model id recorded in a JSONL history, checked both at the top level
    /// and inside a nested `message` object (agents differ on where they put it). Walks
    /// newest-first so a mid-session model switch wins. Best-effort — nil when none present.
    static func latestModel(inJSONL url: URL, maxBytes: Int = 96 * 1024) -> String? {
        for raw in tailLines(of: url, maxBytes: maxBytes).reversed() {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let m = obj["model"] as? String, !m.isEmpty, m != "<synthetic>" { return m }
            if let msg = obj["message"] as? [String: Any],
               let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" { return m }
        }
        return nil
    }

    /// The first JSON object of a JSONL file — used for agents that put session metadata
    /// (cwd, description, …) on the opening line. Best-effort: nil when absent/unparseable.
    static func firstJSON(in url: URL, maxBytes: Int = 64 * 1024) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: true).first,
              let d = first.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Read a whole JSON file as an object, capped to bound memory. Best-effort.
    static func readJSONObject(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Read a whole JSON file as an array of objects, capped to bound memory. Best-effort.
    static func readJSONArray(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    // MARK: - Sub-agents

    /// The expensive-to-read bits of a sub-agent transcript, cached across polls: the
    /// immutable spawn task (read once) and the latest activity (re-read only when the
    /// file changes). Keyed by agent id in the caller's cache.
    struct SubAgentCache { var mtime: Date; var title: String; var lastMessage: String }

    /// Discover a session's active background sub-agents. Claude Code writes each one to
    /// `<session-id>/subagents/agent-*.jsonl` (a sidechain), so while the parent waits its
    /// own transcript is quiet and these are the only sign of progress. Only the session's
    /// direct sub-agents are surfaced (not a sub-agent's own nested sub-agents).
    ///
    /// `cache` avoids re-reading each file every poll: the task is read once (immutable),
    /// and the activity line is re-read only when the file's mtime changes. The `working`
    /// flag is always recomputed from the current time, so it stays live without I/O.
    static func subAgents(inDir dir: URL, activeWindow: TimeInterval, workingWindow: TimeInterval,
                          max: Int = 8, cache: inout [String: SubAgentCache]) -> [SubAgent] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let now = Date()
        let recent: [(url: URL, mtime: Date)] = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return now.timeIntervalSince(m) < activeWindow ? (url, m) : nil
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(max)
            .map { $0 }
        return recent.map { entry in
            let id = entry.url.deletingPathExtension().lastPathComponent
            let title: String
            let lastMessage: String
            if let hit = cache[id], hit.mtime == entry.mtime {
                title = hit.title; lastMessage = hit.lastMessage   // file unchanged — no I/O
            } else {
                title = cache[id]?.title ?? (firstUserText(in: entry.url) ?? "Sub-agent")
                lastMessage = activityLine(in: entry.url)
                cache[id] = SubAgentCache(mtime: entry.mtime, title: title, lastMessage: lastMessage)
            }
            return SubAgent(id: id, title: title, lastMessage: lastMessage,
                            working: now.timeIntervalSince(entry.mtime) < workingWindow,
                            updatedAt: entry.mtime)
        }
    }

    /// The task a sub-agent was spawned with — its first user turn is the spawn prompt.
    static func firstUserText(in url: URL, maxBytes: Int = 16 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }
            if let s = msg["content"] as? String { return firstLine(s) }
            if let arr = msg["content"] as? [[String: Any]] {
                for b in arr where (b["type"] as? String) == "text" {
                    if let t = b["text"] as? String, !t.isEmpty { return firstLine(t) }
                }
            }
        }
        return nil
    }

    /// A one-line "what it's doing now" summary from a transcript's newest turn.
    static func activityLine(in url: URL, maxBytes: Int = 32 * 1024) -> String {
        for raw in tailLines(of: url, maxBytes: maxBytes).reversed() {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "assistant" || type == "user",
               let msg = obj["message"] as? [String: Any],
               let s = summarize(type: type, content: msg["content"]) {
                return firstLine(s)
            }
        }
        return "Working"
    }

    /// Total tokens used across the whole session by summing per-message `usage`
    /// (input + output + cache read/creation). Reads the full file, so callers should
    /// cache the result by file modification time.
    static func sessionTokens(in url: URL, maxBytes: Int = 12_000_000) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let data: Data = size > UInt64(maxBytes)
            ? ((try? handle.read(upToCount: maxBytes)) ?? Data())
            : ((try? handle.readToEnd()) ?? Data())
        let text = String(decoding: data, as: UTF8.self)

        var total = 0
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            // Count fresh tokens only: input + output + cache writes. Cache *reads* are
            // excluded because they re-count the same context on every turn, which would
            // inflate the total into the tens of millions for a long session.
            total += (usage["input_tokens"] as? Int ?? 0)
            total += (usage["output_tokens"] as? Int ?? 0)
            total += (usage["cache_creation_input_tokens"] as? Int ?? 0)
        }
        return total
    }

    /// Reads only the last chunk of the file (transcripts can be large) and returns
    /// a human-readable activity line plus session metadata (branch, cwd, entrypoint)
    /// from the most recent entries that carry each field.
    static func latestActivity(in url: URL, maxBytes: Int = 96 * 1024) -> Activity {
        // Decode the tail once and share it with both scans below.
        let objs: [[String: Any]] = tailLines(of: url, maxBytes: maxBytes).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
        }
        var branch: String?
        var cwd: String?
        var entrypoint: String?
        var model: String?
        var summary: String?
        var tasks: [AgentTask]?

        // Walk newest -> oldest, filling each field from the first entry that has it.
        for obj in objs.reversed() {
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if entrypoint == nil, let e = obj["entrypoint"] as? String, !e.isEmpty { entrypoint = e }

            if (obj["type"] as? String) == "assistant" || (obj["type"] as? String) == "user",
               let message = obj["message"] as? [String: Any] {
                let type = obj["type"] as? String
                if summary == nil { summary = TranscriptReader.summarize(type: type, content: message["content"]) }
                // The newest TodoWrite call holds the session's whole current todo list.
                if tasks == nil { tasks = todos(from: message["content"]) }
                // The model of the most recent assistant turn is the session's current model
                // (a mid-session `/model` switch shows up as a newer entry, seen first here).
                if model == nil, let m = message["model"] as? String, m != "<synthetic>" {
                    model = ModelName.pretty(m)
                }
            }

            if branch != nil && cwd != nil && entrypoint != nil
                && model != nil && summary != nil && tasks != nil { break }
        }
        return Activity(text: summary ?? "Session active",
                        branch: branch, cwd: cwd, entrypoint: entrypoint,
                        model: model, tasks: tasks ?? [],
                        question: pendingQuestion(in: objs))
    }

    /// Detects an unanswered `AskUserQuestion` in the transcript tail — the poll-path
    /// equivalent of the hook's question interception. Walks oldest→newest tracking the
    /// most recent `AskUserQuestion` tool_use and clearing it once a matching `tool_result`
    /// (the answer) appears, so a question only survives while it's genuinely pending.
    ///
    /// A pending ask is the *last* thing in the conversation — the agent is blocked on it.
    /// So it's also treated as resolved if anything meaningful follows it: a matching
    /// `tool_result`, a later assistant turn, or a human prompt. That guards against hosts
    /// that record the answer as a plain continuation rather than a tool_result (otherwise
    /// the card could linger forever with no way to clear it).
    private static func pendingQuestion(in objs: [[String: Any]]) -> AgentQuestion? {
        // Keep the real turns (skip meta rows: attachments, system notices, etc.).
        struct Turn { let role: String; let blocks: [[String: Any]]; let text: String? }
        var turns: [Turn] = []
        for obj in objs {
            guard let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            if let blocks = message["content"] as? [[String: Any]] {
                turns.append(Turn(role: type, blocks: blocks, text: nil))
            } else if let str = message["content"] as? String {
                turns.append(Turn(role: type, blocks: [], text: str))
            }
        }

        // Find the most recent AskUserQuestion tool_use.
        var askIndex: Int?
        var parts: [QuestionPart]?
        for (i, turn) in turns.enumerated() where turn.role == "assistant" {
            for block in turn.blocks where (block["type"] as? String) == "tool_use"
                && (block["name"] as? String) == "AskUserQuestion" {
                if let p = questionParts(from: block["input"] as? [String: Any]) {
                    askIndex = i
                    parts = p
                }
            }
        }
        guard let idx = askIndex, let parts else { return nil }

        // Pending only if nothing meaningful comes after the ask.
        let continued = turns[(idx + 1)...].contains { turn in
            if let text = turn.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return turn.blocks.contains {
                ["text", "tool_use", "tool_result"].contains($0["type"] as? String ?? "")
            }
        }
        return continued ? nil : AgentQuestion(parts: parts, source: .transcript)
    }

    /// Parses `AskUserQuestion`'s `questions` input into card parts. Mirrors the hook:
    /// options come from each choice's `label`, and every question offers a free-text
    /// answer (`allowsOther`) since the poll path can't gate on option-only replies.
    private static func questionParts(from input: [String: Any]?) -> [QuestionPart]? {
        guard let questions = input?["questions"] as? [[String: Any]] else { return nil }
        let parts: [QuestionPart] = questions.enumerated().compactMap { idx, q in
            let options = (q["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
                .filter { !$0.isEmpty }
            let header = (q["header"] as? String) ?? ""
            let prompt = (q["question"] as? String) ?? header
            guard !prompt.isEmpty || !options.isEmpty else { return nil }
            return QuestionPart(id: idx,
                                header: header,
                                prompt: prompt.isEmpty ? "Choose an option" : prompt,
                                options: options,
                                multiSelect: (q["multiSelect"] as? Bool) ?? false,
                                allowsOther: true)
        }
        return parts.isEmpty ? nil : parts
    }

    /// Extracts the todo list from a message's content if it contains a `TodoWrite`
    /// tool call. Claude Code rewrites the entire list on every call, so the most recent
    /// one is the current state — callers walk newest-first and take the first hit.
    private static func todos(from content: Any?) -> [AgentTask]? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks where (block["type"] as? String) == "tool_use"
            && (block["name"] as? String) == "TodoWrite" {
            guard let input = block["input"] as? [String: Any],
                  let items = input["todos"] as? [[String: Any]] else { return nil }
            let parsed: [AgentTask] = items.enumerated().compactMap { idx, item in
                // Prefer the imperative `content`; fall back to `activeForm` if that's all there is.
                let text = (item["content"] as? String) ?? (item["activeForm"] as? String) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let state: AgentTask.State
                switch item["status"] as? String {
                case "completed":   state = .completed
                case "in_progress": state = .inProgress
                default:            state = .pending
                }
                return AgentTask(id: idx, text: clamp(trimmed, 140), state: state)
            }
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    // MARK: - Full chat

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses the tail of a transcript into an ordered list of chat messages for the
    /// live conversation view. Reads a generous tail (transcripts can be huge) and keeps
    /// the most recent `limit` messages so rendering stays cheap.
    static func messages(in url: URL, maxBytes: Int = 512 * 1024, limit: Int = 80) -> [ChatMessage] {
        let lines = tailLines(of: url, maxBytes: maxBytes)
        var out: [ChatMessage] = []
        for raw in lines {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let msg = message(from: obj) { out.append(msg) }
        }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }

    /// Converts a single transcript entry into a chat message, or nil for meta rows
    /// (queue operations, titles, hook attachments, system notices…).
    private static func message(from obj: [String: Any]) -> ChatMessage? {
        guard let type = obj["type"] as? String,
              type == "user" || type == "assistant",
              let message = obj["message"] as? [String: Any] else { return nil }
        let uuid = (obj["uuid"] as? String) ?? UUID().uuidString
        let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
        let content = message["content"]

        // A user entry with plain-string content is a real human prompt.
        if type == "user", let str = content as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ChatMessage(id: uuid, role: .user, blocks: [.text(clamp(trimmed, 4000))], timestamp: ts)
        }

        guard let arr = content as? [[String: Any]] else { return nil }
        var blocks: [ChatBlock] = []
        var sawToolResult = false
        for block in arr {
            switch block["type"] as? String {
            case "text":
                if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    blocks.append(.text(clamp(t, 4000)))
                }
            case "thinking":
                if let t = (block["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    blocks.append(.thinking(clamp(t, 1200)))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                blocks.append(.toolUse(name: name, detail: argDetail(block["input"] as? [String: Any])))
            case "tool_result":
                sawToolResult = true
                let text = toolResultText(block["content"])
                if !text.isEmpty { blocks.append(.toolResult(clamp(text, 600))) }
            default:
                break
            }
        }
        guard !blocks.isEmpty else { return nil }
        // Tool results arrive on `user`-type entries but belong to the agent's work,
        // so render them on the assistant side.
        let role: ChatMessage.Role = (type == "assistant" || sawToolResult) ? .assistant : .user
        return ChatMessage(id: uuid, role: role, blocks: blocks, timestamp: ts)
    }

    /// Pull a concise target out of a tool-call input dict (path, command, pattern…).
    /// Shared by the Claude parser and the other-agent parsers, whose arguments arrive
    /// as a JSON string (see `toolDetail(fromArgumentsJSON:)`).
    static func argDetail(_ input: [String: Any]?) -> String? {
        let target = (input?["file_path"] as? String ?? input?["path"] as? String)
                .map { ($0 as NSString).lastPathComponent }
            ?? (input?["command"] as? String)
            ?? (input?["pattern"] as? String)
            ?? (input?["description"] as? String)
        guard let target, !target.isEmpty else { return nil }
        return clamp(target, 120)
    }

    /// Same as `argDetail`, but the arguments are a JSON string (Grok/Copilot tool calls).
    static func toolDetail(fromArgumentsJSON json: Any?) -> String? {
        guard let str = json as? String,
              let data = str.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return argDetail(dict)
    }

    /// Flattens a tool_result's content (string or array of text blocks) to plain text.
    private static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = content as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func clamp(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
    }

    /// Turns a message's content into a short status line.
    private static func summarize(type: String?, content: Any?) -> String? {
        // Assistant/user content is usually an array of blocks.
        if let blocks = content as? [[String: Any]] {
            // Prefer the last tool use — that's the most concrete "doing X" signal.
            for block in blocks.reversed() {
                let btype = block["type"] as? String
                if btype == "tool_use", let name = block["name"] as? String {
                    return toolLine(name: name, input: block["input"] as? [String: Any])
                }
            }
            for block in blocks.reversed() {
                if (block["type"] as? String) == "text",
                   let text = block["text"] as? String, !text.isEmpty {
                    return prefixed(type, firstLine(text))
                }
                if (block["type"] as? String) == "tool_result" {
                    return "Reviewing result"
                }
            }
        }
        // User content is sometimes a plain string.
        if let str = content as? String, !str.isEmpty {
            return prefixed(type, firstLine(str))
        }
        return nil
    }

    private static func toolLine(name: String, input: [String: Any]?) -> String {
        let target = (input?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input?["command"] as? String).map { String($0.prefix(40)) }
            ?? (input?["pattern"] as? String)
        switch name {
        case "Edit", "Write", "MultiEdit": return "Editing \(target ?? "a file")"
        case "Read": return "Reading \(target ?? "a file")"
        case "Bash": return "Running: \(target ?? "command")"
        case "Grep", "Glob": return "Searching \(target ?? "")"
        default: return "Using \(name)"
        }
    }

    private static func prefixed(_ type: String?, _ text: String) -> String {
        type == "user" ? "You: \(text)" : text
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 70 ? String(trimmed.prefix(70)) + "…" : trimmed
    }

    /// Reads the last `maxBytes` of the file and splits into lines.
    static func tailLines(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        // Drop a possibly-truncated first line when we didn't start at byte 0.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
