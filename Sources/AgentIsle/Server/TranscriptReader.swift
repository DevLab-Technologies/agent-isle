import Foundation

/// Reads the tail of a Claude Code `*.jsonl` transcript to derive a one-line summary
/// of what the session is currently doing, plus the active git branch.
enum TranscriptReader {
    struct Activity {
        var text: String
        var branch: String?
        var cwd: String?
        var entrypoint: String?
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
    static func latestActivity(in url: URL, maxBytes: Int = 64 * 1024) -> Activity {
        let lines = tailLines(of: url, maxBytes: maxBytes)
        var branch: String?
        var cwd: String?
        var entrypoint: String?
        var summary: String?

        // Walk newest -> oldest, filling each field from the first entry that has it.
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if entrypoint == nil, let e = obj["entrypoint"] as? String, !e.isEmpty { entrypoint = e }

            if summary == nil {
                let type = obj["type"] as? String
                if type == "assistant" || type == "user",
                   let message = obj["message"] as? [String: Any] {
                    summary = TranscriptReader.summarize(type: type, content: message["content"])
                }
            }

            if branch != nil && cwd != nil && entrypoint != nil && summary != nil { break }
        }
        return Activity(text: summary ?? "Session active",
                        branch: branch, cwd: cwd, entrypoint: entrypoint)
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
                blocks.append(.toolUse(name: name, detail: toolDetail(name: name, input: block["input"] as? [String: Any])))
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

    /// Short "what the tool is doing" line, reusing the same phrasing as the status tail.
    private static func toolDetail(name: String, input: [String: Any]?) -> String? {
        let target = (input?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input?["command"] as? String)
            ?? (input?["pattern"] as? String)
            ?? (input?["description"] as? String)
        guard let target, !target.isEmpty else { return nil }
        return clamp(target, 120)
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

    private static func clamp(_ text: String, _ max: Int) -> String {
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
    private static func tailLines(of url: URL, maxBytes: Int) -> [String] {
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
