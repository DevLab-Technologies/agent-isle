import Foundation

/// A Claude Code session that Claude Desktop runs on a remote host over SSH.
struct RemoteSession {
    let id: UUID              // deterministic from `cliSessionID` — see `RemoteSessions`
    let cliSessionID: String  // CLI session uuid, used for the `claude://resume` deep link
    let title: String
    let cwd: String?          // working directory *on the remote host*
    let model: String?
    let startedAt: Date
    let updatedAt: Date
    let ssh: SSHTarget        // how to reach the host, for `RemoteTranscriptSync`
    /// Absolute path of the transcript *on the remote host*, as Desktop recorded it.
    /// Preferred over locating the file ourselves: it is exact, and it handles hosts where
    /// the transcript isn't under the SSH user's home (a root session, a git worktree).
    let remoteTranscriptPath: String?

    /// Display name of the host, without the `user@` prefix.
    var host: String { ssh.displayHost }
}

/// Everything needed to open an SSH connection to the host a session runs on, as Claude
/// Desktop recorded it.
struct SSHTarget: Equatable {
    let destination: String     // "user@host" as Desktop stored it
    let port: Int?
    let identityFile: String?   // may be tilde-relative, e.g. "~/.ssh/id_ed25519"

    var displayHost: String {
        destination.split(separator: "@").last.map(String.init) ?? destination
    }
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
        // Most files here describe *local* sessions, and each carries a large
        // `remoteMcpServersConfig` blob — so test for the marker in the raw bytes and skip
        // the JSON decode entirely for those. This runs on the main actor every poll.
        guard let data = readCapped(url), data.range(of: Self.sshConfigMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sshConfig = obj["sshConfig"] as? [String: Any], // absent ⇒ runs locally, IdeWatcher has it
              let ssh = target(from: sshConfig),
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
            cwd: cwd,
            model: ModelName.pretty(obj["model"] as? String),
            startedAt: epochMillis(obj["createdAt"]) ?? updatedAt,
            updatedAt: updatedAt,
            ssh: ssh,
            remoteTranscriptPath: (obj["sshRemoteTranscriptPath"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 })
    }

    private static let sshConfigMarker = Data("\"sshConfig\"".utf8)

    /// Read a session file, capped so a pathological one can't be pulled into memory whole.
    private static func readCapped(_ url: URL, maxBytes: Int = 4 * 1024 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// The SSH connection details, or nil when there's no usable host — without one the
    /// session can't be reached, so it isn't a remote session we can do anything with.
    static func target(from config: [String: Any]) -> SSHTarget? {
        guard let destination = (config["sshHost"] as? String)?
            .trimmingCharacters(in: .whitespaces), !destination.isEmpty else { return nil }
        let identity = (config["sshIdentityFile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SSHTarget(destination: destination,
                         port: config["sshPort"] as? Int,
                         identityFile: identity)
    }

    /// Desktop records timestamps as milliseconds since the epoch, as a JSON number.
    private static func epochMillis(_ value: Any?) -> Date? {
        guard let ms = value as? Double, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
