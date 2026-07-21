import Foundation
import SQLite3

/// Read-only reader for the Cursor CLI's per-session `store.db`.
///
/// Cursor (`cursor-agent`) keeps each chat under
/// `~/.cursor/chats/<md5-of-project-path>/<session-uuid>/store.db` — a SQLite database
/// with two tables:
///
///   - `meta(key, value)`: session metadata at `key = "0"`, whose `value` is
///     **hex-encoded JSON** (`name`, `lastUsedModel`, `createdAt` in epoch ms,
///     `latestRootBlobId`, `agentId`, `mode`).
///   - `blobs(id, data)`: a content-addressed Merkle-DAG. `id` is the hex SHA-256 of
///     `data`; `data` is either a JSON message (first byte `{`) or a length-delimited
///     protobuf "linking" blob whose 32-byte values are child blob ids.
///
/// The format was reverse-engineered from several independent readers (SpecStory,
/// sidecar, ctxmv). Every read here is best-effort and never throws: a schema change, a
/// locked database, or an unexpected blob shape just yields no data, and the caller falls
/// back to a metadata-only row or the chat view's empty state.
///
/// Two access patterns, deliberately split by cost:
///   - `summary` is the scanner's hot path (runs every couple of seconds per active
///     session). It only touches the `meta` row, the root blob (indexed by id), and the
///     newest few blobs — never the whole table.
///   - `messages` reconstructs the full conversation from the DAG for the chat view, and
///     is only called on demand when a session is opened.
enum CursorStore {

    struct Meta {
        var agentId: String?
        var name: String?
        var mode: String?
        var createdAt: Date?
        var lastUsedModel: String?
        var latestRootBlobId: String?
    }

    /// Cheap per-session snapshot for the session list.
    struct Summary {
        var meta: Meta
        var lastMessage: String?
        var workspacePath: String?
    }

    private struct Blob {
        let rowid: Int64
        let id: String        // lowercased hex SHA-256
        let data: Data
    }

    // Bound how much of a pathologically large database we pull into memory for the full
    // conversation read; the scanner's hot path never loads this many.
    private static let maxBlobs = 5_000
    // Newest blobs to inspect for the one-line summary / workspace fallback.
    private static let scanTail = 60

    // MARK: - Scanner hot path

    /// A single-open snapshot: metadata, a one-line activity summary, and the workspace
    /// path — without loading the whole blob table. nil if the database can't be read.
    static func summary(at url: URL) -> Summary? {
        withDB(url) { db -> Summary? in
            guard let meta = readMeta(db) else { return nil }
            let tail = newestBlobs(db, limit: scanTail)
            return Summary(meta: meta,
                           lastMessage: lastMessageLine(in: tail),
                           workspacePath: workspacePath(db, meta: meta, tail: tail))
        }
    }

    /// Decoded `meta` row, or nil if the database can't be opened or has no meta.
    static func meta(at url: URL) -> Meta? {
        withDB(url) { readMeta($0) }
    }

    /// A one-line summary of the newest user/assistant turn (standalone; `summary` folds
    /// this into one open).
    static func lastMessageText(at url: URL) -> String? {
        withDB(url) { lastMessageLine(in: newestBlobs($0, limit: scanTail)) }
    }

    /// The session's working directory (standalone; `summary` folds this into one open).
    static func workspacePath(at url: URL) -> String? {
        withDB(url) { db in workspacePath(db, meta: readMeta(db), tail: newestBlobs(db, limit: scanTail)) }
    }

    // MARK: - Full conversation (chat view, on demand)

    /// The full conversation, reconstructed from the blob DAG, most recent `limit` kept.
    static func messages(at url: URL, limit: Int = 80) -> [ChatMessage] {
        withDB(url) { db -> [ChatMessage] in
            let blobs = loadBlobs(db)
            guard !blobs.isEmpty else { return [] }

            let byID = Dictionary(blobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let root = readMeta(db)?.latestRootBlobId

            // Restrict to blobs reachable from the current root so orphaned/older duplicate
            // roots are dropped; if the root is missing or leads nowhere, fall back to every
            // blob in insertion order.
            let reachable = root.flatMap { byID[$0] != nil ? reachableIDs(from: $0, in: byID) : nil }

            let ordered = blobs.filter { reachable?.contains($0.id) ?? true }
            var out: [ChatMessage] = []
            for blob in ordered {
                guard isJSON(blob.data),
                      let obj = try? JSONSerialization.jsonObject(with: blob.data) as? [String: Any],
                      let msg = message(from: obj, id: blob.id) else { continue }
                out.append(msg)
            }
            return out.count > limit ? Array(out.suffix(limit)) : out
        } ?? []
    }

    // MARK: - Summary derivation

    /// The newest blob that decodes to a user/assistant message with visible text, as a
    /// one-line status. `blobs` is expected newest-first.
    private static func lastMessageLine(in blobs: [Data]) -> String? {
        for data in blobs {
            guard isJSON(data),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = message(from: obj, id: "") else { continue }
            for block in msg.blocks {
                if case .text(let t) = block {
                    let line = t.split(separator: "\n").first.map(String.init) ?? t
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        return (msg.role == .user ? "You: " : "") + TranscriptReader.clamp(trimmed, 90)
                    }
                }
            }
        }
        return nil
    }

    /// The session's cwd, recovered from the `file://` workspace URI Cursor embeds in the
    /// conversation root blob (the on-disk folder name is only an MD5 of the path). Reads
    /// the root blob by id when known, else scans the newest blobs (the root is usually
    /// among them). Best-effort — nil when not present.
    private static func workspacePath(_ db: OpaquePointer, meta: Meta?, tail: [Data]) -> String? {
        if let root = meta?.latestRootBlobId, let data = blobData(db, id: root),
           let path = fileURIPath(in: data) {
            return path
        }
        for data in tail {
            if let path = fileURIPath(in: data) { return path }
        }
        return nil
    }

    // MARK: - DAG traversal

    /// The set of blob ids reachable from `root`, following protobuf reference bytes. Used
    /// only to filter out unreferenced blobs; ordering comes from `rowid`, not this walk.
    private static func reachableIDs(from root: String, in byID: [String: Blob]) -> Set<String> {
        var seen: Set<String> = []
        var stack = [root]
        while let id = stack.popLast() {
            guard !seen.contains(id), let blob = byID[id] else { continue }
            seen.insert(id)
            if !isJSON(blob.data) {
                for child in childReferences(in: blob.data) where byID[child] != nil {
                    if !seen.contains(child) { stack.append(child) }
                }
            }
        }
        return seen
    }

    /// Extract child blob ids from a linking blob. Matches SpecStory's tolerant scan:
    /// a protobuf field tag (`0x0a`/`0x12`/`0x42`) followed by length `0x20` and 32 bytes
    /// that look like a real hash (high non-printable-byte count), rather than trusting
    /// exact field numbers, which vary by Cursor version.
    private static func childReferences(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 34 else { return [] }
        var out: [String] = []
        var i = 0
        while i + 34 <= bytes.count {
            let tag = bytes[i]
            if (tag == 0x0a || tag == 0x12 || tag == 0x42) && bytes[i + 1] == 0x20 {
                let slice = bytes[(i + 2)..<(i + 34)]
                let nonPrintable = slice.reduce(0) { $0 + (($1 < 0x20 || $1 > 0x7e) ? 1 : 0) }
                if nonPrintable >= 8 {
                    out.append(slice.map { String(format: "%02x", $0) }.joined())
                    i += 34
                    continue
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - Message parsing

    /// Convert one JSON message blob into a `ChatMessage`. The blob's own hash is the id
    /// (the JSON `id` is often a non-unique "1"). Returns nil for empty / system turns.
    private static func message(from obj: [String: Any], id: String) -> ChatMessage? {
        guard let role = obj["role"] as? String, role == "user" || role == "assistant" || role == "tool"
        else { return nil }

        var blocks: [ChatBlock] = []
        if let text = obj["content"] as? String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.text(TranscriptReader.clamp(strippingQueryTags(t), 4000))) }
        } else if let arr = obj["content"] as? [[String: Any]] {
            for block in arr {
                switch block["type"] as? String {
                case "text":
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        blocks.append(.text(TranscriptReader.clamp(strippingQueryTags(t), 4000)))
                    }
                case "reasoning":
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        blocks.append(.thinking(TranscriptReader.clamp(t, 1200)))
                    }
                case "tool-call":
                    let name = block["toolName"] as? String ?? "Tool"
                    blocks.append(.toolUse(name: name, detail: toolArgDetail(block["args"])))
                case "tool-result":
                    let text = toolResultText(block["result"])
                    if !text.isEmpty { blocks.append(.toolResult(TranscriptReader.clamp(text, 600))) }
                default:
                    break
                }
            }
        }
        guard !blocks.isEmpty else { return nil }
        // Tool turns are the agent's work — render them on the assistant side.
        let mapped: ChatMessage.Role = role == "user" ? .user : .assistant
        return ChatMessage(id: "cursor-\(id)", role: mapped, blocks: blocks)
    }

    private static func toolArgDetail(_ args: Any?) -> String? {
        if let dict = args as? [String: Any] { return TranscriptReader.argDetail(dict) }
        return TranscriptReader.toolDetail(fromArgumentsJSON: args)
    }

    private static func toolResultText(_ result: Any?) -> String {
        if let s = result as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let arr = result as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Cursor wraps a human prompt in `<user_query>…</user_query>`; strip the tags so the
    /// row shows the real prompt.
    private static func strippingQueryTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<user_query>", with: "")
         .replacingOccurrences(of: "</user_query>", with: "")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Blob / file:// helpers

    /// The path portion of the first embedded `file://` URI in a blob, percent-decoded.
    /// Best-effort: the URI lives in a length-delimited protobuf field, but we don't parse
    /// the framing (field numbers vary by Cursor version), so we read until a control/quote
    /// byte. A trailing printable byte could over-read by a few chars — acceptable because
    /// the cwd only feeds Jump (which falls back) and a title we prefer `meta.name` for.
    private static func fileURIPath(in data: Data) -> String? {
        // The URI is plain ASCII inside an otherwise-binary blob; decode leniently and scan
        // for the scheme rather than requiring the whole blob to be valid UTF-8.
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "file://") else { return nil }
        let rest = text[range.upperBound...]
        // Stop at the first control/quote byte that can't be part of a path.
        let raw = rest.prefix { ch in
            guard let a = ch.asciiValue else { return false }
            return a >= 0x20 && a != 0x22   // printable ASCII, not a double-quote
        }
        let path = String(raw).removingPercentEncoding ?? String(raw)
        return path.isEmpty ? nil : path
    }

    private static func isJSON(_ data: Data) -> Bool {
        for byte in data {
            if byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d { continue }
            return byte == 0x7b   // '{'
        }
        return false
    }

    // MARK: - Meta decode

    private static func readMeta(_ db: OpaquePointer) -> Meta? {
        guard let raw = firstColumnText(db, "SELECT value FROM meta WHERE key='0' LIMIT 1"),
              let json = hexToJSON(raw) else { return nil }
        let created = (json["createdAt"] as? Double) ?? (json["createdAt"] as? NSNumber)?.doubleValue
        return Meta(
            agentId: json["agentId"] as? String,
            name: (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: json["mode"] as? String,
            createdAt: created.map { Date(timeIntervalSince1970: $0 / 1000.0) },
            lastUsedModel: json["lastUsedModel"] as? String,
            latestRootBlobId: (json["latestRootBlobId"] as? String)?.lowercased())
    }

    private static func hexToJSON(_ hex: String) -> [String: Any]? {
        guard let data = dataFromHex(hex) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }

    // MARK: - SQLite

    /// Open the database read-only and run `body`. Read-only tolerates the live WAL that
    /// `cursor-agent` keeps open; a failure to open (locked, missing, corrupt) yields nil.
    private static func withDB<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        return body(db)
    }

    /// Every blob in insertion order (bounded), for the full conversation reconstruction.
    private static func loadBlobs(_ db: OpaquePointer) -> [Blob] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, id, data FROM blobs ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [Blob] = []
        while sqlite3_step(stmt) == SQLITE_ROW, out.count < maxBlobs {
            let rowid = sqlite3_column_int64(stmt, 0)
            guard let idC = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: idC).lowercased()
            guard let data = columnBlob(stmt, 2) else { continue }
            out.append(Blob(rowid: rowid, id: id, data: data))
        }
        return out
    }

    /// The newest `limit` blob payloads (by insertion order), for the cheap summary reads.
    private static func newestBlobs(_ db: OpaquePointer, limit: Int) -> [Data] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM blobs ORDER BY rowid DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let data = columnBlob(stmt, 0) { out.append(data) }
        }
        return out
    }

    /// A single blob's payload, looked up by its content hash id.
    private static func blobData(_ db: OpaquePointer, id: String) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM blobs WHERE id=? LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT: sqlite copies the string, so the Swift buffer needn't outlive the call.
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnBlob(stmt, 0)
    }

    private static func columnBlob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        let len = sqlite3_column_bytes(stmt, col)
        guard len > 0, let raw = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: raw, count: Int(len))
    }

    private static func firstColumnText(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}
