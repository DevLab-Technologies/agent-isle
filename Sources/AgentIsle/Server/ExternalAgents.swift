import Foundation

/// A session discovered from a non-Claude agent's on-disk history.
struct ExternalSession {
    let id: UUID
    let agent: AgentKind
    let terminal: String
    let title: String
    let lastMessage: String
    let cwd: String?
    let mtime: Date
    let model: String?    // display name of the model, e.g. "Grok 4" (nil if the format hides it)
    let historyURL: URL   // on-disk conversation file, parsed by ChatHistory for the chat view
}

/// Hook-free watchers for other coding agents. Each agent stores its history
/// differently, so there is one small adapter per tool. Adapters are best-effort and
/// never throw — a format change just means that agent stops appearing.
enum ExternalAgents {
    static func scanAll(activeWindow: TimeInterval, maxPerAgent: Int) -> [ExternalSession] {
        var out: [ExternalSession] = []
        out += Grok.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Copilot.scan(activeWindow: activeWindow, limit: maxPerAgent)
        return out
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Grok CLI  (~/.grok/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl)

    enum Grok {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let root = home.appendingPathComponent(".grok/sessions")
            let fm = FileManager.default
            guard let cwdDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

            var found: [ExternalSession] = []
            let now = Date()
            for cwdDir in cwdDirs where cwdDir.hasDirectoryPath {
                let cwd = cwdDir.lastPathComponent.removingPercentEncoding ?? cwdDir.lastPathComponent
                guard let sessionDirs = try? fm.contentsOfDirectory(at: cwdDir, includingPropertiesForKeys: nil) else { continue }
                for sess in sessionDirs where sess.hasDirectoryPath {
                    let history = sess.appendingPathComponent("chat_history.jsonl")
                    guard let mtime = modDate(history), now.timeIntervalSince(mtime) < activeWindow else { continue }
                    let msg = TranscriptReader.lastText(in: history) { obj in
                        grokText(obj)
                    }
                    found.append(ExternalSession(
                        id: UUID.deterministic(from: "grok:" + sess.lastPathComponent),
                        agent: .grok,
                        terminal: "Grok CLI",
                        title: (cwd as NSString).lastPathComponent,
                        lastMessage: msg ?? "Session active",
                        cwd: cwd,
                        mtime: mtime,
                        model: ModelName.pretty(TranscriptReader.latestModel(inJSONL: history)),
                        historyURL: history))
                }
            }
            return topN(found, limit)
        }

        /// Extract a readable line from a Grok chat entry.
        private static func grokText(_ obj: [String: Any]) -> String? {
            let type = obj["type"] as? String
            guard type == "assistant" || type == "user" else { return nil }
            if let s = obj["content"] as? String, !s.isEmpty { return s }
            if let blocks = obj["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "text" {
                    if let t = b["text"] as? String, !t.isEmpty {
                        return t.replacingOccurrences(of: "<user_query>", with: "")
                                .replacingOccurrences(of: "</user_query>", with: "")
                    }
                }
            }
            return nil
        }
    }

    // MARK: - GitHub Copilot CLI  (~/.copilot/history-session-state/session_*.json)

    enum Copilot {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let dir = home.appendingPathComponent(".copilot/history-session-state")
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }

            var found: [ExternalSession] = []
            let now = Date()
            for file in files where file.pathExtension == "json" {
                guard let mtime = modDate(file), now.timeIntervalSince(mtime) < activeWindow else { continue }
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let sessionID = (obj["sessionId"] as? String) ?? file.lastPathComponent
                let messages = obj["chatMessages"] as? [[String: Any]] ?? []
                let last = messages.reversed().first { m in
                    (m["role"] as? String) != nil && (m["content"] as? String)?.isEmpty == false
                }
                let text = (last?["content"] as? String).map { String($0.prefix(90)) } ?? "Session active"
                let cwd = obj["cwd"] as? String ?? obj["workspaceFolder"] as? String
                // Model may sit at the top level or on the latest message that records one.
                let rawModel = (obj["model"] as? String)
                    ?? messages.compactMap { $0["model"] as? String }.last

                found.append(ExternalSession(
                    id: UUID.deterministic(from: "copilot:" + sessionID),
                    agent: .copilot,
                    terminal: "Copilot CLI",
                    title: cwd.map { ($0 as NSString).lastPathComponent } ?? "copilot",
                    lastMessage: text,
                    cwd: cwd,
                    mtime: mtime,
                    model: ModelName.pretty(rawModel),
                    historyURL: file))
            }
            return topN(found, limit)
        }
    }

    // MARK: - Helpers

    private static func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func topN(_ sessions: [ExternalSession], _ n: Int) -> [ExternalSession] {
        Array(sessions.sorted { $0.mtime > $1.mtime }.prefix(n))
    }
}
