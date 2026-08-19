import Foundation

/// Strips the machine-injected envelopes Claude Code writes into the *user* side of a
/// transcript, so they never reach the chat view as if a human had typed them.
///
/// Claude Code delivers several kinds of non-human input on user turns: background-task
/// completions (`<task-notification>`), context injections (`<system-reminder>`), slash
/// command invocations (`<command-name>` + `<local-command-stdout>`), and hook output.
/// Rendered verbatim these are walls of XML that dominate the panel and bury the actual
/// conversation. Each one is either dropped or condensed to a single line of notice text.
///
/// Deliberately conservative: anything not recognised as an envelope is left exactly as
/// the user wrote it, so a prompt that merely *mentions* one of these tags survives intact.
enum ChatNoise {
    /// What one user-turn's raw text should become on screen.
    enum Outcome: Equatable {
        /// Real human text, with any envelopes around it removed.
        case message(String)
        /// A machine-injected turn, reduced to one dim line.
        case notice(String)
        /// Nothing worth showing at all.
        case drop
    }

    /// Envelopes that carry no user-facing meaning — removed outright.
    private static let silent = ["system-reminder", "local-command-caveat",
                                 "user-prompt-submit-hook", "ide_selection", "ide_opened_file"]
    /// Slash-command scaffolding — the invocation itself becomes the notice.
    private static let commandTags = ["command-message", "command-args", "local-command-stdout"]

    static func sanitize(_ raw: String) -> Outcome {
        var text = raw
        var notices: [String] = []

        for tag in silent { text = removing(tag, from: text).stripped }

        // Background task completions: keep the summary, drop the machinery around it.
        let tasks = removing("task-notification", from: text)
        if !tasks.captured.isEmpty {
            text = tasks.stripped
            for body in tasks.captured {
                notices.append(inner("summary", of: body).map { "Background task: \($0)" }
                               ?? "Background task finished")
            }
        }

        // Slash commands arrive as <command-name>/foo</command-name> plus its output.
        let names = removing("command-name", from: text)
        if !names.captured.isEmpty {
            text = names.stripped
            for tag in commandTags { text = removing(tag, from: text).stripped }
            for name in names.captured {
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                notices.append(n.isEmpty ? "Slash command" : "Ran \(n.hasPrefix("/") ? n : "/" + n)")
            }
        }

        let remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty { return .message(remaining) }
        if let first = notices.first { return .notice(condense(first)) }
        return .drop
    }

    // MARK: - Tag surgery

    /// Removes every `<tag>…</tag>` occurrence, returning what is left and what was inside.
    private static func removing(_ tag: String, from text: String)
        -> (stripped: String, captured: [String]) {
        guard text.contains("<\(tag)"),
              let re = try? NSRegularExpression(pattern: "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>",
                                                options: [.dotMatchesLineSeparators]) else {
            return (text, [])
        }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, []) }
        let captured = matches.map { ns.substring(with: $0.range(at: 1)) }
        var out = text
        // Back to front, so earlier ranges stay valid as later ones are cut.
        for m in matches.reversed() {
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        return (out, captured)
    }

    /// The text of a single nested `<tag>` inside an already-captured body.
    private static func inner(_ tag: String, of body: String) -> String? {
        let found = removing(tag, from: body).captured.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (found?.isEmpty ?? true) ? nil : found
    }

    /// Notices are one glanceable line, never a paragraph.
    private static func condense(_ s: String) -> String {
        let oneLine = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(139)) + "…" : oneLine
    }
}
