import Foundation

/// Mirrors a remote session's Claude Code transcript to this Mac, so everything the local
/// poll path derives from a transcript works for sessions running over SSH too.
///
/// `RemoteSessions` gives us a live *card* for an SSH session, but only what Desktop's
/// session store records: title, host, model, liveness. The activity line, token total,
/// todo list and pending `AskUserQuestion` all come from the transcript — which Claude
/// Code writes on the remote host.
///
/// So we fetch it. Each sync appends only the bytes that are new (`tail -c +<offset>`),
/// leaving a full copy under `~/.agent-isle/remote-transcripts/<cli-session-id>.jsonl`
/// that `TranscriptReader` and `ChatHistory` read exactly as they read a local one.
///
/// Constraints this design answers:
///   • **Cost** — the first sync transfers the file, later ones only the delta, and
///     connections are reused via SSH's `ControlMaster` rather than re-handshaking.
///   • **The UI must never block** — `Process` runs off-main with a hard watchdog, one
///     sync in flight per session, and a cadence far slower than the 2s scan.
///   • **No prompts** — `BatchMode=yes` makes an unreachable host or a passphrase-locked
///     key fail fast instead of hanging on stdin. Host-key checking is left at its
///     default: Desktop has already connected to this host, so the key is known, and
///     auto-accepting a *new* one is not a trade we should make silently.
@MainActor
final class RemoteTranscriptSync {

    /// How often to re-sync one session. Slower than the 2s scan — this is network I/O,
    /// and a transcript that changed mid-interval is still only seconds stale.
    private let interval: TimeInterval = 6
    /// Give up on a sync that hangs despite `ConnectTimeout` (a wedged connection, a host
    /// that accepts TCP then stalls), so a session can't leak a stuck process per poll.
    private let timeout: TimeInterval = 25
    /// Cap on the first transfer. Beyond this we take only the tail, trading an exact
    /// token total for not pulling a huge file over the network in one go.
    private let initialByteCap = 8 * 1024 * 1024

    /// Ceiling on the backoff after repeated failures — long enough that an unreachable
    /// host costs almost nothing, short enough that one coming back is noticed promptly.
    private let maxRetryInterval: TimeInterval = 300

    private struct State {
        var offset: Int = 0        // bytes of the remote file already accounted for
        var lastSync: Date = .distantPast
        var inFlight = false
        var failure: String?       // last error, shown on the card so failures aren't silent
        var consecutiveFailures = 0
    }

    /// How long to wait before the next attempt: the normal interval, doubling per
    /// consecutive failure. Without this an unreachable host is retried at full cadence for
    /// as long as its card is live, each attempt spawning an `ssh` that blocks on connect.
    private func retryInterval(after state: State) -> TimeInterval {
        guard state.consecutiveFailures > 0 else { return interval }
        let doubled = interval * pow(2, Double(min(state.consecutiveFailures, 8)))
        return min(doubled, maxRetryInterval)
    }

    private var states: [String: State] = [:]
    private let cacheDir: URL

    init() {
        let parent = EventAuthToken.directoryURL
        try? EventAuthToken.ensurePrivateDirectory(parent)
        cacheDir = parent.appendingPathComponent("remote-transcripts")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// The mirrored transcript for a session, or nil until the first sync lands.
    func transcript(for cliSessionID: String) -> URL? {
        let url = cacheURL(cliSessionID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Why the last sync failed, if it did — surfaced on the card rather than swallowed,
    /// since a silently empty transcript looks identical to an idle session.
    func failure(for cliSessionID: String) -> String? { states[cliSessionID]?.failure }

    /// Start a sync for `session` if one is due and none is running. Returns immediately.
    func syncIfNeeded(_ session: RemoteSession) {
        let id = session.cliSessionID
        var state = states[id] ?? restoredState(id)
        guard !state.inFlight,
              Date().timeIntervalSince(state.lastSync) >= retryInterval(after: state) else { return }
        state.inFlight = true
        state.lastSync = Date()
        states[id] = state

        let (target, offset, cap) = (session.ssh, state.offset, initialByteCap)
        let (dest, path, limit) = (cacheURL(id), session.remoteTranscriptPath, timeout)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.fetch(target: target, cliSessionID: id, path: path, offset: offset,
                                    initialByteCap: cap, timeout: limit)
            Task { @MainActor [weak self] in
                self?.apply(result, id: id, dest: dest, requestedOffset: offset)
            }
        }
    }

    /// Drop state and mirrored transcripts for sessions that are no longer live, so the
    /// cache can't grow without bound as sessions come and go.
    ///
    /// Sweeps the directory rather than just the in-memory state, so mirrors orphaned by a
    /// previous run (the app quit before their session ended) are collected too.
    func prune(live: Set<String>) {
        for id in states.keys where !live.contains(id) {
            // A sync still in flight owns its state until it lands; dropping it here would
            // let the next scan start a second one against a stale offset.
            guard states[id]?.inFlight != true else { continue }
            states.removeValue(forKey: id)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" || file.pathExtension == "offset" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !live.contains(id), states[id]?.inFlight != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Applying a result

    private enum FetchResult {
        case data(size: Int, delta: Data)
        case failed(String)
    }

    private func apply(_ result: FetchResult, id: String, dest: URL, requestedOffset: Int) {
        var state = states[id] ?? State()
        state.inFlight = false
        defer { states[id] = state }

        switch result {
        case .failed(let message):
            state.failure = message
            state.consecutiveFailures += 1
        case .data(let size, let delta):
            state.failure = nil
            state.consecutiveFailures = 0
            // The remote file shrank (a new session reusing the id, or a truncated file):
            // our mirror no longer matches, so start over on the next pass.
            if size < requestedOffset {
                state.offset = 0
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.removeItem(at: offsetURL(id))
                return
            }
            guard !delta.isEmpty else { return }
            if requestedOffset == 0 {
                try? delta.write(to: dest, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: dest) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: delta)
            } else {
                // The mirror vanished under us (manual delete, cache cleanup). Re-fetch
                // whole rather than appending a delta onto nothing.
                state.offset = 0
                try? FileManager.default.removeItem(at: offsetURL(id))
                return
            }
            // Resume from the file's end, not from how many bytes we received. On the
            // first sync of a transcript larger than `initialByteCap` those differ: we
            // hold only the tail, so counting the delta would resume mid-file and splice
            // an unrelated stretch into the mirror.
            state.offset = size
            persist(offset: size, for: id)
        }
    }

    private func cacheURL(_ cliSessionID: String) -> URL {
        cacheDir.appendingPathComponent("\(cliSessionID).jsonl")
    }

    /// The mirror's resume point, stored beside it so a relaunch continues where the last
    /// run stopped instead of re-downloading every live session's transcript.
    ///
    /// It has to be recorded rather than inferred: a mirror first synced past
    /// `initialByteCap` holds only the tail, so its own file size is *smaller* than the
    /// remote offset it stands for, and resuming from that size would splice an unrelated
    /// stretch of the remote file into it.
    private func offsetURL(_ cliSessionID: String) -> URL {
        cacheDir.appendingPathComponent("\(cliSessionID).offset")
    }

    /// State for a session we haven't synced yet this run, picking up a mirror left behind
    /// by a previous one. Falls back to a full re-fetch if anything doesn't line up.
    ///
    /// The record pairs the remote offset with the mirror's size at the moment it was
    /// written, and the resume point is only trusted while the mirror still has that size.
    /// The append happens before the record is updated, so a process killed between them
    /// (the app SIGKILLs an older copy of itself on launch) would otherwise leave an offset
    /// that under-reports the mirror — and the next sync would append that stretch a second
    /// time, double-counting its tokens and replaying its messages for good.
    private func restoredState(_ id: String) -> State {
        var state = State()
        guard let text = try? String(contentsOf: offsetURL(id), encoding: .utf8) else { return state }
        let fields = text.split(separator: " ").compactMap { Int($0) }
        guard fields.count == 2, fields[0] > 0,
              let actual = mirrorSize(id), actual == fields[1] else { return state }
        state.offset = fields[0]
        return state
    }

    private func persist(offset: Int, for id: String) {
        guard let size = mirrorSize(id) else { return }
        try? String("\(offset) \(size)").write(to: offsetURL(id), atomically: true, encoding: .utf8)
    }

    private func mirrorSize(_ id: String) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: cacheURL(id).path)[.size] as? Int
    }

    // MARK: - Fetching

    /// Run one `ssh` round trip. Off-main; returns the file's current size plus the bytes
    /// after `offset`.
    ///
    /// `cliSessionID` is a validated UUID before it reaches here (`RemoteSessions.parse`
    /// rejects anything else), so it is safe to interpolate into the remote command — no
    /// path from the store's JSON reaches the shell unvalidated.
    nonisolated private static func fetch(target: SSHTarget, cliSessionID: String, path: String?,
                                          offset: Int, initialByteCap: Int,
                                          timeout: TimeInterval) -> FetchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(target: target)
            + [remoteCommand(cliSessionID: cliSessionID, path: path, offset: offset,
                             initialByteCap: initialByteCap)]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return .failed("couldn't run ssh: \(error.localizedDescription)")
        }

        // Kill a hung connection rather than leaking the process and its pipes.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Drain both pipes before waiting, and drain them concurrently: a transcript larger
        // than the pipe buffer deadlocks if we wait for exit first, and reading them in
        // sequence deadlocks the same way if ssh fills stderr while we're stuck on stdout.
        let errorPipe = err
        var errorText = ""
        let stderrDrained = DispatchGroup()
        stderrDrained.enter()
        DispatchQueue.global(qos: .utility).async {
            errorText = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                               as: UTF8.self)
            stderrDrained.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else {
            return .failed(describe(status: process.terminationStatus, stderr: errorText))
        }
        // First line is the file's byte count, the rest is the requested tail.
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let size = Int(String(decoding: data[..<newline], as: UTF8.self)
                  .trimmingCharacters(in: .whitespaces)) else {
            return .failed("unexpected response from host")
        }
        return .data(size: size, delta: Data(data[data.index(after: newline)...]))
    }

    nonisolated private static func sshArguments(target: SSHTarget) -> [String] {
        var args = [
            "-o", "BatchMode=yes",          // fail instead of prompting for a password
            "-o", "ConnectTimeout=5",
            // Reuse one connection across polls: without this every sync pays a full TCP
            // and auth handshake, several times a minute per session.
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=120",
        ]
        if let port = target.port, port != 22 { args += ["-p", String(port)] }
        if let identity = target.identityFile {
            args += ["-i", (identity as NSString).expandingTildeInPath]
        }
        return args + [target.destination]
    }

    /// `%C` is a hash of host/port/user, so each destination gets its own socket.
    nonisolated private static var controlPath: String {
        let dir = EventAuthToken.directoryURL
        try? EventAuthToken.ensurePrivateDirectory(dir)
        return dir.appendingPathComponent("ssh-%C").path
    }

    /// Print the transcript's size, then the bytes after `offset` — one round trip, with
    /// the size letting the caller notice a truncated or replaced file.
    ///
    /// Desktop usually records the transcript's exact remote path, which we prefer: it is
    /// authoritative, and it covers hosts where the file isn't under the SSH user's home
    /// (a `root` session, a git worktree's own encoded directory). When it's absent we fall
    /// back to locating the file by session id, since the directory name is derived from
    /// the cwd and we'd rather not reimplement that encoding.
    nonisolated static func remoteCommand(cliSessionID: String, path: String?, offset: Int,
                                          initialByteCap: Int) -> String {
        // `tail -c +N` is 1-indexed: +1 is the whole file.
        let tail = offset > 0
            ? "tail -c +\(offset + 1) \"$f\""
            // First sync of a large transcript: take the last `initialByteCap` bytes. The
            // caller's offset then trails the real file, which the size check reconciles.
            : "tail -c \(initialByteCap) \"$f\""
        // The path comes from a JSON file we don't author, so it is single-quoted with
        // embedded quotes escaped — it reaches the remote shell as one literal word and
        // can't extend the command. The session id is a validated UUID (see `parse`).
        let locate = path.map { "f=\(shellQuoted($0))" }
            ?? "f=$(ls -1t \"$HOME\"/.claude/projects/*/\(cliSessionID).jsonl 2>/dev/null | head -1)"
        return """
        \(locate)
        [ -f "$f" ] || exit 3
        wc -c < "$f" | tr -d ' '
        \(tail)
        """
    }

    /// Wrap a string so a POSIX shell reads it as a single literal argument.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Turn an ssh exit status into something worth showing on a card.
    nonisolated private static func describe(status: Int32, stderr: String) -> String {
        if status == 3 { return "no transcript on host yet" }
        let firstLine = stderr.split(separator: "\n").first.map(String.init) ?? ""
        if firstLine.contains("Permission denied") { return "ssh key rejected by host" }
        if firstLine.contains("Could not resolve") || firstLine.contains("Name or service") {
            return "host not found"
        }
        if firstLine.contains("Connection timed out") || firstLine.contains("Operation timed out") {
            return "host unreachable"
        }
        if firstLine.contains("Host key verification failed") { return "host key not trusted" }
        return firstLine.isEmpty ? "ssh failed (\(status))" : String(firstLine.prefix(80))
    }
}
