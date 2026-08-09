import Foundation

/// A Claude Code session that Claude Desktop runs on a remote host over SSH.
struct RemoteSession {
    let id: UUID              // deterministic from `cliSessionID` — see `RemoteSessions`
    let cliSessionID: String  // CLI session uuid, used for the `claude://resume` deep link
    let title: String
    let host: String?         // host part of `sshHost`, e.g. "ezpayments-production"
    let cwd: String?          // working directory *on the remote host*
    let model: String?
    let startedAt: Date
    let updatedAt: Date
}

/// Discovers Claude Code sessions running over SSH, which `IdeWatcher` cannot see.
///
/// `IdeWatcher` finds sessions by tailing `~/.claude/projects/**/<uuid>.jsonl`. A session
/// Claude Desktop runs over SSH executes `claude` on the *remote* host, so that transcript
/// is written there, not here. Desktop mirrors some of them back into
/// `~/.claude/projects/ssh-<cli-session-id>/`, but only some and only well after the
/// session starts — it can't be relied on to surface a session while it is live.
///
/// Desktop's own session store is the authoritative live record. It keeps one JSON file
/// per session at
/// `~/Library/Application Support/Claude/claude-code-sessions/<profile>/<workspace>/local_<uuid>.json`
/// and rewrites it as the session progresses, so the file's mtime tracks activity. An
/// `sshConfig` object is what marks a session as remote.
///
/// This yields less than the transcript path does — no activity line, token totals or
/// todo list, since those are only derivable from the transcript on the remote host — but
/// title, model, cwd and liveness are enough for a card.
enum RemoteSessions {
    /// Remote sessions touched within `activeWindow`, most-recently-active first.
    ///
    /// Best-effort, like the `ExternalAgents` adapters: a format change means SSH sessions
    /// stop appearing rather than anything breaking. The store holds every session ever
    /// created (hundreds), so files are filtered by mtime before being parsed — only the
    /// handful that are actually live get read on each poll.
    static func scan(activeWindow: TimeInterval, limit: Int,
                     root: URL? = nil) -> [RemoteSession] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = fm.enumerator(at: root ?? storeRoot, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles]) else { return [] }

        var found: [RemoteSession] = []
        let now = Date()
        for case let url as URL in walker {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("local_"),
                  let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  now.timeIntervalSince(mtime) < activeWindow,
                  let session = parse(url, mtime: mtime) else { continue }
            found.append(session)
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private static var storeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Read one session file, returning nil unless it describes a live remote session.
    private static func parse(_ url: URL, mtime: Date) -> RemoteSession? {
        guard let obj = TranscriptReader.readJSONObject(url, maxBytes: 4 * 1024 * 1024),
              obj["sshConfig"] is [String: Any],           // absent ⇒ runs locally, IdeWatcher has it
              (obj["isArchived"] as? Bool) != true,
              // The CLI session id keys the card. It matches the mirrored transcript's
              // filename, so a session that *does* get mirrored later reuses this id
              // instead of appearing twice.
              let cliSessionID = obj["cliSessionId"] as? String,
              UUID(uuidString: cliSessionID) != nil else { return nil }

        let cwd = (obj["cwd"] as? String) ?? (obj["originCwd"] as? String)
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? cwd.map { ($0 as NSString).lastPathComponent }
            ?? "Remote session"
        let updatedAt = epochMillis(obj["lastActivityAt"]) ?? mtime

        return RemoteSession(
            id: UUID.deterministic(from: cliSessionID),
            cliSessionID: cliSessionID,
            title: title,
            host: host(from: obj["sshConfig"] as? [String: Any]),
            cwd: cwd,
            model: ModelName.pretty(obj["model"] as? String),
            startedAt: epochMillis(obj["createdAt"]) ?? updatedAt,
            updatedAt: updatedAt)
    }

    /// The bare hostname from an `sshConfig`, dropping the `user@` prefix so the card
    /// shows "ezpayments-production" rather than "elkhayyat@ezpayments-production".
    private static func host(from config: [String: Any]?) -> String? {
        guard let raw = config?["sshHost"] as? String, !raw.isEmpty else { return nil }
        return raw.split(separator: "@").last.map(String.init) ?? raw
    }

    /// Desktop records timestamps as milliseconds since the epoch, as a JSON number.
    private static func epochMillis(_ value: Any?) -> Date? {
        guard let ms = value as? Double, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
