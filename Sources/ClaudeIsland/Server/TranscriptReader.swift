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
