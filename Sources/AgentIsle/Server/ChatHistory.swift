import Foundation

/// Loads a session's full conversation from whichever on-disk format its agent uses,
/// so the live chat view can show previous messages for every supported agent — not just
/// Claude Code. Claude has its own JSONL transcript (see `TranscriptReader`); the other
/// agents each store history differently, so there is one small parser per tool here.
///
/// Every parser is best-effort and never throws: an unrecognised or changed format simply
/// yields no messages, and the chat view falls back to its empty-state notice.
enum ChatHistory {
    /// The most recent `limit` messages for `agent`, parsed from the file at `url`.
    static func messages(for agent: AgentKind, url: URL, limit: Int = 80) -> [ChatMessage] {
        switch agent {
        case .grok:    return grok(url, limit: limit)
        case .copilot: return copilot(url, limit: limit)
        default:       return TranscriptReader.messages(in: url, limit: limit)
        }
    }

    /// Whether we know how to read a chat history for this agent at all. Sessions of an
    /// unsupported agent (or with no file yet) show the "no history" notice instead.
    static func isSupported(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude, .grok, .copilot: return true
        default: return false
        }
    }

    // Cap how much of a history file we read, to bound memory on a pathologically long
    // session. Real files sit well under this, so in practice the whole file is read from
    // byte 0 — which keeps line/array indices (and thus the synthesized message ids) stable
    // across the tailer's repeated reads. Above the cap, ids may shift once; that only costs
    // a re-render, and a JSON file that can't be read whole simply yields no history.
    private static let maxBytes = 8 * 1024 * 1024

    // MARK: - Grok CLI  (chat_history.jsonl)

    /// Grok stores one JSON object per line: `user`/`assistant` turns, `reasoning`
    /// (thinking) entries, and `tool_result`s. Assistant turns carry inline `tool_calls`.
    private static func grok(_ url: URL, limit: Int) -> [ChatMessage] {
        let lines = TranscriptReader.tailLines(of: url, maxBytes: maxBytes)
        var out: [ChatMessage] = []
        for (idx, raw) in lines.enumerated() {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let id = "grok-\(idx)"

            switch type {
            case "user":
                if let text = grokText(obj["content"]) {
                    out.append(ChatMessage(id: id, role: .user, blocks: [.text(TranscriptReader.clamp(text, 4000))]))
                }
            case "assistant":
                var blocks: [ChatBlock] = []
                if let t = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    blocks.append(.text(TranscriptReader.clamp(t, 4000)))
                }
                for call in obj["tool_calls"] as? [[String: Any]] ?? [] {
                    let name = call["name"] as? String ?? "Tool"
                    blocks.append(.toolUse(name: name, detail: TranscriptReader.toolDetail(fromArgumentsJSON: call["arguments"])))
                }
                if !blocks.isEmpty {
                    out.append(ChatMessage(id: id, role: .assistant, blocks: blocks))
                }
            case "reasoning":
                if let text = grokReasoning(obj["summary"]) {
                    out.append(ChatMessage(id: id, role: .assistant, blocks: [.thinking(TranscriptReader.clamp(text, 1200))]))
                }
            case "tool_result":
                if let s = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    out.append(ChatMessage(id: id, role: .assistant, blocks: [.toolResult(TranscriptReader.clamp(s, 600))]))
                }
            default:
                break
            }
        }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }

    /// A user turn's content is either a plain string or an array of `text` blocks; the
    /// human prompt is sometimes wrapped in `<user_query>` tags we strip for readability.
    private static func grokText(_ content: Any?) -> String? {
        if let s = content as? String {
            let t = clean(s)
            return t.isEmpty ? nil : t
        }
        if let blocks = content as? [[String: Any]] {
            let parts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            let joined = clean(parts.joined(separator: "\n"))
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// `reasoning` entries expose a `summary` array of `summary_text` blocks.
    private static func grokReasoning(_ summary: Any?) -> String? {
        guard let blocks = summary as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { $0["text"] as? String }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<user_query>", with: "")
         .replacingOccurrences(of: "</user_query>", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - GitHub Copilot CLI  (session_*.json)

    /// Copilot stores the whole conversation in one JSON file under `chatMessages`, each
    /// with a `role` (`user`/`assistant`/`tool`). Assistant messages may instead carry
    /// `tool_calls` (`{function:{name, arguments}}`), and `tool` messages are results.
    private static func copilot(_ url: URL, limit: Int) -> [ChatMessage] {
        // A single JSON document, so it must be read whole — but cap the read so a runaway
        // file can't blow up memory. Over the cap the JSON is truncated and simply won't
        // parse, which degrades to "no history" rather than an unbounded allocation.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["chatMessages"] as? [[String: Any]] else { return [] }

        var out: [ChatMessage] = []
        for (idx, m) in messages.enumerated() {
            let role = m["role"] as? String
            let id = "copilot-\(idx)"

            switch role {
            case "user":
                if let t = (m["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    out.append(ChatMessage(id: id, role: .user, blocks: [.text(TranscriptReader.clamp(t, 4000))]))
                }
            case "assistant":
                var blocks: [ChatBlock] = []
                if let t = (m["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    blocks.append(.text(TranscriptReader.clamp(t, 4000)))
                }
                for call in m["tool_calls"] as? [[String: Any]] ?? [] {
                    let fn = call["function"] as? [String: Any]
                    let name = fn?["name"] as? String ?? "Tool"
                    blocks.append(.toolUse(name: name, detail: TranscriptReader.toolDetail(fromArgumentsJSON: fn?["arguments"])))
                }
                if !blocks.isEmpty {
                    out.append(ChatMessage(id: id, role: .assistant, blocks: blocks))
                }
            case "tool":
                if let t = (m["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    out.append(ChatMessage(id: id, role: .assistant, blocks: [.toolResult(TranscriptReader.clamp(t, 600))]))
                }
            default:
                break
            }
        }
        return out.count > limit ? Array(out.suffix(limit)) : out
    }
}
