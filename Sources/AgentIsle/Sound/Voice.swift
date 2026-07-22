import Foundation

/// Which engine turns text into speech.
///
/// `.system` is the default and is fully local/offline — nothing leaves the machine. The
/// cloud options are opt-in "bring your own key" providers: the user supplies their own API
/// key and is billed by that provider directly; Agent Isle runs no backend and takes no cut.
enum VoiceProvider: String, CaseIterable, Identifiable {
    case system      // Apple AVSpeechSynthesizer — local, free, offline
    case openAI      // OpenAI /v1/audio/speech (BYO key)
    case elevenLabs  // ElevenLabs text-to-speech (BYO key)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:     return "System (on-device)"
        case .openAI:     return "OpenAI"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    /// True for providers that make a network request (and thus require a key).
    var isCloud: Bool { self != .system }

    /// Keychain account holding this provider's key, or nil for the local engine.
    var keyAccount: String? {
        switch self {
        case .system:     return nil
        case .openAI:     return Keychain.Account.openAIKey
        case .elevenLabs: return Keychain.Account.elevenLabsKey
        }
    }
}

/// Who writes the sentence that gets spoken.
///
/// `.heuristic` composes the line locally from the session's own fields — no network. The
/// cloud options ask a small LLM to phrase a tighter, more natural one-liner (BYO key).
enum SummaryProvider: String, CaseIterable, Identifiable {
    case heuristic   // local, template-based, offline
    case openAI      // OpenAI chat completions (BYO key)
    case anthropic   // Anthropic messages (BYO key)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristic: return "Built-in (on-device)"
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var isCloud: Bool { self != .heuristic }

    var keyAccount: String? {
        switch self {
        case .heuristic: return nil
        case .openAI:    return Keychain.Account.openAIKey
        case .anthropic: return Keychain.Account.anthropicKey
        }
    }
}

/// How verbose / how playful the spoken line is.
enum VoiceStyle: String, CaseIterable, Identifiable {
    case terse       // "Claude done."
    case standard    // "Claude finished: fix auth bug."
    case detailed    // standard + the latest activity line
    case playful     // lighter phrasing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terse:    return "Terse"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        case .playful:  return "Playful"
        }
    }
}

/// The kind of moment being announced. Drives both the phrasing and whether it's gated by
/// the "announce completions" vs "announce attention" preference.
enum VoiceEventKind {
    case permission
    case question
    case plan
    case done

    /// Attention events (a decision is needed) are grouped under one toggle; completions
    /// under another.
    var isAttention: Bool { self != .done }
}

/// Everything `VoiceAnnouncer` needs to decide whether and how to speak. A value type so
/// `AppSettings` can rebuild it and hand a fresh copy over on every change.
struct VoiceConfig {
    var provider: VoiceProvider = .system
    var summaryProvider: SummaryProvider = .heuristic
    var style: VoiceStyle = .standard
    var distinctVoicePerAgent = true
    var volume: Double = 0.9
    var announceOnDone = true
    var announceOnAttention = false
    /// OpenAI voice name (e.g. "nova") or ElevenLabs voice id. Empty uses a sensible default.
    var cloudVoice = ""

    func shouldAnnounce(_ kind: VoiceEventKind) -> Bool {
        kind.isAttention ? announceOnAttention : announceOnDone
    }
}

/// Deterministic index into a list of `count` items from a string — `String.hashValue` is
/// salted per process, so we roll our own stable hash (djb2) to keep an agent mapped to the
/// same voice across relaunches. Free (nonisolated) so both the main-actor announcer and the
/// off-actor speech client can share it.
func stableIndex(_ string: String, count: Int) -> Int {
    guard count > 0 else { return 0 }
    var hash: UInt64 = 5381
    for byte in string.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return Int(hash % UInt64(count))
}

/// Composes the spoken line locally from a session's own fields. Pure and synchronous — the
/// always-available default, and the fallback whenever a cloud summary is off or fails.
enum VoiceSummary {
    static func line(for session: AgentSession, kind: VoiceEventKind, style: VoiceStyle) -> String {
        let name = session.agent.displayName
        switch kind {
        case .done:
            return done(name: name, session: session, style: style)
        case .permission:
            return permission(name: name, session: session)
        case .question:
            let q = spoken(session.question?.summary ?? session.lastMessage)
            return q.isEmpty ? "\(name) has a question." : "\(name) has a question. \(q)"
        case .plan:
            return "\(name) shared a plan for review."
        }
    }

    private static func done(name: String, session: AgentSession, style: VoiceStyle) -> String {
        let title = spoken(session.title)
        let activity = spoken(session.lastMessage)
        switch style {
        case .terse:
            return "\(name) done."
        case .standard:
            return title.isEmpty ? "\(name) finished." : "\(name) finished: \(title)."
        case .detailed:
            let base = title.isEmpty ? "\(name) finished." : "\(name) finished: \(title)."
            // Only add the activity line when it says something the title didn't.
            return activity.isEmpty || activity == title ? base : "\(base) \(activity)."
        case .playful:
            return title.isEmpty ? "\(name) just wrapped up." : "\(name) just wrapped up \(title)."
        }
    }

    private static func permission(name: String, session: AgentSession) -> String {
        guard let p = session.permission else { return "\(name) needs your approval." }
        let tool = spoken(p.toolName)
        if let path = p.filePath, !path.isEmpty {
            let file = (path as NSString).lastPathComponent
            return "\(name) wants permission to \(tool.lowercased()) \(file)."
        }
        return "\(name) wants permission to run \(tool)."
    }

    /// Normalize a raw activity/title string into something worth speaking: collapse
    /// whitespace, drop a leading status glyph, and cap the length at a word boundary so a
    /// stray giant line can't produce a minute-long utterance.
    static func spoken(_ raw: String, limit: Int = 160) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        guard s.count > limit else { return s }
        let clipped = String(s.prefix(limit))
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[..<lastSpace]) + "…"
        }
        return clipped + "…"
    }
}
