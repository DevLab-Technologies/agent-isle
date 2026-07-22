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
        out += Cursor.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Codex.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += OpenCode.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Goose.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Cline.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Qwen.scan(activeWindow: activeWindow, limit: maxPerAgent)
        out += Aider.scan(activeWindow: activeWindow, limit: maxPerAgent)
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

    // MARK: - Cursor CLI  (~/.cursor/chats/<md5-of-cwd>/<session-uuid>/store.db)

    enum Cursor {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let root = home.appendingPathComponent(".cursor/chats")
            let fm = FileManager.default
            guard let workspaceDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

            var found: [ExternalSession] = []
            let now = Date()
            for workspaceDir in workspaceDirs where workspaceDir.hasDirectoryPath {
                guard let sessionDirs = try? fm.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: nil) else { continue }
                for sess in sessionDirs where sess.hasDirectoryPath {
                    let db = sess.appendingPathComponent("store.db")
                    // The WAL sidecar is what changes on a live write, so it dates activity
                    // more reliably than store.db itself.
                    let mtime = [db, sess.appendingPathComponent("store.db-wal")]
                        .compactMap(modDate).max()
                    guard let mtime, fm.fileExists(atPath: db.path),
                          now.timeIntervalSince(mtime) < activeWindow else { continue }

                    // One open per session: metadata + activity line + cwd, without
                    // loading the whole blob table (the scan runs every couple seconds).
                    let summary = CursorStore.summary(at: db)
                    let cwd = summary?.workspacePath
                    let title = summary?.meta.name?.nilIfEmpty
                        ?? cwd.map { ($0 as NSString).lastPathComponent }
                        ?? "cursor"
                    found.append(ExternalSession(
                        id: UUID.deterministic(from: "cursor:" + (summary?.meta.agentId ?? sess.lastPathComponent)),
                        agent: .cursor,
                        terminal: "Cursor CLI",
                        title: title,
                        lastMessage: summary?.lastMessage ?? "Session active",
                        cwd: cwd,
                        mtime: mtime,
                        model: ModelName.pretty(summary?.meta.lastUsedModel),
                        historyURL: db))
                }
            }
            return topN(found, limit)
        }
    }

    // MARK: - Codex CLI  (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
    //
    // VERIFIED: not tested on-disk here (Codex was not installed while writing this).
    // Path and JSONL layout follow OpenAI Codex CLI's documented rollout format: a
    // `session_meta` header line (with `cwd`) followed by `response_item` message lines.
    // Older builds wrote bare `{type:"message",role,content}` lines and a top-level `cwd`,
    // so both shapes are handled.

    enum Codex {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let root = home.appendingPathComponent(".codex/sessions")
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [] }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                NSLog("[AgentIsle] Codex sessions dir present but not enumerable: \(root.path)")
                return []
            }

            var found: [ExternalSession] = []
            let now = Date()
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                guard let mtime = modDate(file), now.timeIntervalSince(mtime) < activeWindow else { continue }
                let meta = TranscriptReader.firstJSON(in: file)
                let cwd = codexCwd(meta)
                let msg = TranscriptReader.lastText(in: file) { codexText($0) }
                if msg == nil {
                    NSLog("[AgentIsle] Codex session found but no readable message: \(file.lastPathComponent)")
                }
                found.append(ExternalSession(
                    id: UUID.deterministic(from: "codex:" + file.deletingPathExtension().lastPathComponent),
                    agent: .codex,
                    terminal: "Codex CLI",
                    title: cwd.map { ($0 as NSString).lastPathComponent } ?? "codex",
                    lastMessage: msg ?? "Session active",
                    cwd: cwd,
                    mtime: mtime,
                    model: ModelName.pretty(TranscriptReader.latestModel(inJSONL: file)),
                    historyURL: file))
            }
            return topN(found, limit)
        }

        /// `cwd` lives on the `session_meta` header's payload, or at the top level in
        /// older rollouts.
        private static func codexCwd(_ obj: [String: Any]?) -> String? {
            guard let obj else { return nil }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { return cwd }
            if let payload = obj["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String, !cwd.isEmpty { return cwd }
            return nil
        }

        /// A readable line from a Codex rollout entry: unwrap the `response_item` payload
        /// (or a bare message), then pull the first text from its content blocks.
        private static func codexText(_ obj: [String: Any]) -> String? {
            let node = (obj["payload"] as? [String: Any]) ?? obj
            let role = node["role"] as? String
            guard role == "user" || role == "assistant" else { return nil }
            if let s = node["content"] as? String, !s.isEmpty { return s }
            if let blocks = node["content"] as? [[String: Any]] {
                for b in blocks {
                    if let t = b["text"] as? String, !t.isEmpty { return t }
                }
            }
            return nil
        }
    }

    // MARK: - OpenCode  (~/.local/share/opencode/storage/session/…)
    //
    // VERIFIED: not tested on-disk here (OpenCode was not installed while writing this).
    // Follows sst/opencode's documented storage layout: per-session info JSON files under
    // `storage/session/**` carrying `title`/`directory`, with message JSON under
    // `storage/message/<sessionID>/*.json`. Layout varies by version, so the reader is
    // defensive and degrades to a monitor-only entry when it can't find a message.

    enum OpenCode {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let root = home.appendingPathComponent(".local/share/opencode/storage")
            let fm = FileManager.default
            let sessionRoot = root.appendingPathComponent("session")
            guard fm.fileExists(atPath: sessionRoot.path) else { return [] }
            guard let walker = fm.enumerator(at: sessionRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                NSLog("[AgentIsle] OpenCode storage present but not enumerable: \(sessionRoot.path)")
                return []
            }

            var found: [ExternalSession] = []
            let now = Date()
            for case let file as URL in walker where file.pathExtension == "json" {
                guard let mtime = modDate(file), now.timeIntervalSince(mtime) < activeWindow else { continue }
                guard let obj = TranscriptReader.readJSONObject(file) else { continue }
                // A session-info file carries a title or directory; skip anything else so we
                // don't surface unrelated JSON (config, cache) as phantom sessions.
                guard obj["title"] != nil || obj["directory"] != nil else { continue }
                let sessionID = (obj["id"] as? String) ?? file.deletingPathExtension().lastPathComponent
                let cwd = (obj["directory"] as? String) ?? (obj["cwd"] as? String)
                let title = (obj["title"] as? String)?.nilIfEmpty
                    ?? cwd.map { ($0 as NSString).lastPathComponent }
                    ?? "opencode"
                let msg = openCodeLastMessage(storageRoot: root, sessionID: sessionID) ?? (obj["title"] as? String)
                found.append(ExternalSession(
                    id: UUID.deterministic(from: "opencode:" + sessionID),
                    agent: .opencode,
                    terminal: "OpenCode",
                    title: title,
                    lastMessage: msg ?? "Session active",
                    cwd: cwd,
                    mtime: mtime,
                    model: nil,
                    historyURL: file))
            }
            return topN(found, limit)
        }

        /// Newest message text for a session, read from the per-session message directory.
        private static func openCodeLastMessage(storageRoot: URL, sessionID: String) -> String? {
            let dir = storageRoot.appendingPathComponent("message/\(sessionID)")
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                return nil
            }
            let newest = files
                .filter { $0.pathExtension == "json" }
                .max { (modDate($0) ?? .distantPast) < (modDate($1) ?? .distantPast) }
            guard let newest, let obj = TranscriptReader.readJSONObject(newest) else { return nil }
            // Message parts are usually an array of `{type:"text", text:"…"}`.
            if let parts = obj["parts"] as? [[String: Any]] {
                for p in parts.reversed() where (p["type"] as? String) == "text" {
                    if let t = p["text"] as? String, !t.isEmpty { return t }
                }
            }
            if let content = obj["content"] as? String, !content.isEmpty { return content }
            return nil
        }
    }

    // MARK: - Goose  (~/.local/share/goose/sessions/*.jsonl)
    //
    // VERIFIED: not tested on-disk here (Goose was not installed while writing this).
    // Follows Block's goose CLI session format: a JSONL file whose first line is metadata
    // (`working_dir`, `description`) and whose remaining lines are `{role, content:[…]}`
    // messages. Handled defensively for format drift.

    enum Goose {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let dir = home.appendingPathComponent(".local/share/goose/sessions")
            let fm = FileManager.default
            guard fm.fileExists(atPath: dir.path) else { return [] }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                NSLog("[AgentIsle] Goose sessions dir present but not readable: \(dir.path)")
                return []
            }

            var found: [ExternalSession] = []
            let now = Date()
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = modDate(file), now.timeIntervalSince(mtime) < activeWindow else { continue }
                let meta = TranscriptReader.firstJSON(in: file)
                let cwd = (meta?["working_dir"] as? String) ?? (meta?["cwd"] as? String)
                let description = (meta?["description"] as? String)?.nilIfEmpty
                let msg = TranscriptReader.lastText(in: file) { gooseText($0) }
                found.append(ExternalSession(
                    id: UUID.deterministic(from: "goose:" + file.deletingPathExtension().lastPathComponent),
                    agent: .goose,
                    terminal: "Goose",
                    title: description ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "goose",
                    lastMessage: msg ?? "Session active",
                    cwd: cwd,
                    mtime: mtime,
                    model: nil,
                    historyURL: file))
            }
            return topN(found, limit)
        }

        /// A readable line from a Goose message entry.
        private static func gooseText(_ obj: [String: Any]) -> String? {
            let role = obj["role"] as? String
            guard role == "user" || role == "assistant" else { return nil }
            if let s = obj["content"] as? String, !s.isEmpty { return s }
            if let blocks = obj["content"] as? [[String: Any]] {
                for b in blocks {
                    if let t = b["text"] as? String, !t.isEmpty { return t }
                }
            }
            return nil
        }
    }

    // MARK: - Cline  (VS Code global storage: …/globalStorage/saoudrizwan.claude-dev/tasks)
    //
    // VERIFIED: not tested on-disk here (Cline was not installed while writing this).
    // Cline is a VS Code extension; each task is a folder under the extension's
    // `globalStorage` with `ui_messages.json`. Scanned across VS Code and its common forks
    // (Cursor, VSCodium, Windsurf). Monitor-only: the chat view is not wired for this format.

    enum Cline {
        /// Extension id used by Cline's global storage folder.
        private static let extensionID = "saoudrizwan.claude-dev"
        /// `Application Support` sub-dirs for VS Code and the forks that reuse the layout.
        private static let hostDirs = ["Code", "Cursor", "VSCodium", "Windsurf", "Code - Insiders"]

        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let fm = FileManager.default
            let appSupport = home.appendingPathComponent("Library/Application Support")
            var found: [ExternalSession] = []
            let now = Date()
            for host in hostDirs {
                let tasksDir = appSupport
                    .appendingPathComponent("\(host)/User/globalStorage/\(extensionID)/tasks")
                guard fm.fileExists(atPath: tasksDir.path) else { continue }
                guard let taskDirs = try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil) else {
                    NSLog("[AgentIsle] Cline tasks dir present but not readable: \(tasksDir.path)")
                    continue
                }
                for task in taskDirs where task.hasDirectoryPath {
                    let ui = task.appendingPathComponent("ui_messages.json")
                    guard let mtime = modDate(ui), now.timeIntervalSince(mtime) < activeWindow else { continue }
                    let (title, last) = clineSummary(ui)
                    found.append(ExternalSession(
                        id: UUID.deterministic(from: "cline:" + task.lastPathComponent),
                        agent: .cline,
                        terminal: "Cline (\(host))",
                        title: title ?? "cline",
                        lastMessage: last ?? "Session active",
                        cwd: nil,
                        mtime: mtime,
                        model: nil,
                        historyURL: ui))
                }
            }
            return topN(found, limit)
        }

        /// First task line (title) and newest text line (activity) from `ui_messages.json`,
        /// an array of `{ts, type, say/ask, text}` entries.
        private static func clineSummary(_ url: URL) -> (title: String?, last: String?) {
            guard let arr = TranscriptReader.readJSONArray(url) else { return (nil, nil) }
            let title = arr.first { ($0["say"] as? String) == "task" }?["text"] as? String
                ?? arr.first?["text"] as? String
            let last = arr.reversed().compactMap { ($0["text"] as? String)?.nilIfEmpty }.first
            return (title.map { String($0.prefix(60)) }, last.map { String($0.prefix(90)) })
        }
    }

    // MARK: - Qwen Code  (~/.qwen/tmp/<project-hash>/logs.json)
    //
    // ASSUMED / UNVERIFIED: Qwen Code is a fork of Gemini CLI, which logs sessions to
    // `~/.gemini/tmp/<hash>/logs.json`; Qwen is assumed to mirror this under `~/.qwen`.
    // The project directory is a one-way hash, so `cwd` is not recoverable from the path.
    // Monitor-only.

    enum Qwen {
        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            let root = home.appendingPathComponent(".qwen/tmp")
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [] }
            guard let projectDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                NSLog("[AgentIsle] Qwen tmp dir present but not readable: \(root.path)")
                return []
            }

            var found: [ExternalSession] = []
            let now = Date()
            for project in projectDirs where project.hasDirectoryPath {
                let logs = project.appendingPathComponent("logs.json")
                guard let mtime = modDate(logs), now.timeIntervalSince(mtime) < activeWindow else { continue }
                guard let arr = TranscriptReader.readJSONArray(logs) else {
                    NSLog("[AgentIsle] Qwen logs.json present but not parseable: \(logs.path)")
                    continue
                }
                let sessionID = arr.last?["sessionId"] as? String ?? project.lastPathComponent
                let last = arr.reversed().compactMap { ($0["message"] as? String)?.nilIfEmpty }.first
                let firstUser = arr.first { ($0["type"] as? String) == "user" }?["message"] as? String
                found.append(ExternalSession(
                    id: UUID.deterministic(from: "qwen:" + sessionID),
                    agent: .qwen,
                    terminal: "Qwen Code",
                    title: firstUser.map { String($0.prefix(60)) } ?? "qwen",
                    lastMessage: last.map { String($0.prefix(90)) } ?? "Session active",
                    cwd: nil,
                    mtime: mtime,
                    model: nil,
                    historyURL: logs))
            }
            return topN(found, limit)
        }
    }

    // MARK: - Aider  (project-local .aider.chat.history.md)
    //
    // ASSUMED / UNVERIFIED and LIMITED: Aider keeps no central session registry — it writes
    // `.aider.chat.history.md` into whatever directory it runs in. There is no reliable way
    // to enumerate every project from a fixed path, so this only picks up the copy Aider
    // writes when run from the home directory. Projects elsewhere won't be discovered.
    // Monitor-only; the chat view is not wired for Aider's Markdown format.

    enum Aider {
        /// The one location we can check without scanning the whole disk.
        private static var historyFiles: [URL] {
            [home.appendingPathComponent(".aider.chat.history.md")]
        }

        static func scan(activeWindow: TimeInterval, limit: Int) -> [ExternalSession] {
            var found: [ExternalSession] = []
            let now = Date()
            for file in historyFiles {
                guard let mtime = modDate(file), now.timeIntervalSince(mtime) < activeWindow else { continue }
                let last = aiderLastLine(file)
                if last == nil {
                    NSLog("[AgentIsle] Aider history present but no readable line: \(file.path)")
                }
                found.append(ExternalSession(
                    id: UUID.deterministic(from: "aider:" + file.path),
                    agent: .aider,
                    terminal: "Aider",
                    title: (file.deletingLastPathComponent().path as NSString).lastPathComponent,
                    lastMessage: last ?? "Session active",
                    cwd: file.deletingLastPathComponent().path,
                    mtime: mtime,
                    model: nil,
                    historyURL: file))
            }
            return topN(found, limit)
        }

        /// Newest meaningful line from the Markdown transcript: skip blank lines, headings,
        /// and horizontal rules; strip the leading `>`/`####` markers Aider uses.
        private static func aiderLastLine(_ url: URL) -> String? {
            let lines = TranscriptReader.tailLines(of: url, maxBytes: 32 * 1024)
            for raw in lines.reversed() {
                var line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, line != "---" else { continue }
                while line.hasPrefix(">") || line.hasPrefix("#") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                if !line.isEmpty { return String(line.prefix(90)) }
            }
            return nil
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
