import Foundation

/// Scans Claude Code transcripts to build historical token-usage records for the Usage
/// insights view. Unlike `IdeWatcher` (which only surfaces *active* sessions), this walks
/// every transcript on disk and aggregates one record per session per day, so the UI can
/// group by session / project / day / month and filter by time range.
///
/// Pure and best-effort: a file that can't be read or parsed contributes nothing.
enum UsageAnalytics {
    /// One session's usage on a single calendar day.
    struct Record: Equatable {
        let sessionID: String
        let project: String        // display name (folder / cwd leaf)
        let projectPath: String    // full cwd when known
        let agent: AgentKind
        let day: Date              // start of day, local time
        var tokens: Int
        var messages: Int
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Every `*.jsonl` transcript under `projectsDir`, with its modification date so the
    /// caller can cache results and only re-scan files that changed.
    static func transcripts(in projectsDir: URL) -> [(url: URL, mtime: Date)] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(URL, Date)] = []
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append((url, m))
            }
        }
        return out
    }

    /// Parse one transcript into session-day records. `folderName` (the encoded project
    /// directory) is used to derive a project label when the transcript lines omit `cwd`.
    static func scanFile(_ url: URL, folderName: String, maxBytes: Int = 12_000_000) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let data: Data = size > UInt64(maxBytes)
            ? ((try? handle.read(upToCount: maxBytes)) ?? Data())
            : ((try? handle.readToEnd()) ?? Data())
        guard !data.isEmpty else { return [] }

        let sessionID = url.deletingPathExtension().lastPathComponent
        let cal = Calendar.current
        var cwd: String?
        // Accumulate per day so one long session spanning midnight splits correctly.
        var byDay: [Date: (tokens: Int, messages: Int)] = [:]

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            guard let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let tokens = (usage["input_tokens"] as? Int ?? 0)
                + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            guard tokens > 0 else { continue }
            let date = (obj["timestamp"] as? String).flatMap(parseDate) ?? Date.distantPast
            let day = cal.startOfDay(for: date)
            var bucket = byDay[day] ?? (0, 0)
            bucket.tokens += tokens
            bucket.messages += 1
            byDay[day] = bucket
        }

        let projectPath = cwd ?? decodeProjectPath(folderName)
        let project = (projectPath as NSString).lastPathComponent
        return byDay.map { day, v in
            Record(sessionID: sessionID, project: project.isEmpty ? "unknown" : project,
                   projectPath: projectPath, agent: .claude, day: day,
                   tokens: v.tokens, messages: v.messages)
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// Claude encodes a project's cwd as its path with `/` (and `.`) turned into `-`,
    /// e.g. `-Users-me-Dev-app`. We can't losslessly recover it, but the leading dash +
    /// dashes give a readable-enough fallback path when a transcript omits `cwd`.
    private static func decodeProjectPath(_ folder: String) -> String {
        folder.hasPrefix("-") ? "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/") : folder
    }
}
