import Foundation

/// Errors surfaced by the bring-your-own-key cloud providers. Any of them makes the caller
/// fall back to the on-device voice / local summary, so they're informational rather than fatal.
enum VoiceError: LocalizedError {
    case http(Int)
    case badResponse
    case noContent

    var errorDescription: String? {
        switch self {
        case .http(let code): return "provider returned HTTP \(code)"
        case .badResponse:    return "unreadable provider response"
        case .noContent:      return "provider returned no content"
        }
    }
}

/// Cloud text-to-speech (OpenAI, ElevenLabs). Stateless; returns encoded audio bytes ready
/// for `AVAudioPlayer`. Only ever reached when the user has opted into a cloud provider and
/// supplied their own key — this is the only code path that sends text off the machine.
enum SpeechClient {
    /// OpenAI's fixed set of built-in voices, used to give each agent a distinct voice when the
    /// user hasn't pinned one explicitly.
    private static let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo",
                                       "fable", "nova", "onyx", "sage", "shimmer"]
    /// ElevenLabs' "Rachel" — a stable default public voice when the user hasn't supplied a id.
    private static let elevenLabsDefaultVoice = "21m00Tcm4TlvDq8ikWAM"

    static func synthesize(text: String, agent: AgentKind, config: VoiceConfig, key: String) async throws -> Data {
        switch config.provider {
        case .openAI:     return try await openAI(text: text, agent: agent, config: config, key: key)
        case .elevenLabs: return try await elevenLabs(text: text, config: config, key: key)
        case .system:     throw VoiceError.badResponse   // not a cloud provider
        }
    }

    private static func openAI(text: String, agent: AgentKind, config: VoiceConfig, key: String) async throws -> Data {
        let voice = config.cloudVoice.isEmpty
            ? (config.distinctVoicePerAgent ? openAIVoices[stableIndex(agent.rawValue, count: openAIVoices.count)] : "nova")
            : config.cloudVoice
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            // tts-1 is available on every account with API access; the newer gpt-4o-mini-tts
            // requires extra access and would otherwise fail silently to the on-device voice.
            "model": "tts-1",
            "voice": voice,
            "input": text,
            "response_format": "mp3",
        ])
        return try await audioBytes(for: req)
    }

    private static func elevenLabs(text: String, config: VoiceConfig, key: String) async throws -> Data {
        let voiceID = config.cloudVoice.isEmpty ? elevenLabsDefaultVoice : config.cloudVoice
        // The voice id goes into the URL path; a user-entered value may contain characters that
        // make `URL(string:)` fail. Encode it, and throw (fall back to on-device) instead of
        // force-unwrapping nil and crashing.
        let encoded = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(encoded)") else {
            throw VoiceError.badResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
        ])
        return try await audioBytes(for: req)
    }

    private static func audioBytes(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoiceError.http(http.statusCode) }
        guard !data.isEmpty else { throw VoiceError.noContent }
        return data
    }
}

/// Optional AI-written one-liner (OpenAI, Anthropic). Turns a session's state into a tight
/// spoken sentence. Stateless; only reached when the user selects a cloud summary provider and
/// supplies a key. Failure throws so the caller keeps the local `VoiceSummary` line.
enum SummaryClient {
    static func summarize(session: AgentSession, kind: VoiceEventKind, style: VoiceStyle,
                          provider: SummaryProvider, key: String) async throws -> String {
        let system = systemPrompt(style: style)
        let user = context(session: session, kind: kind)
        switch provider {
        case .openAI:    return try await openAI(system: system, user: user, key: key)
        case .anthropic: return try await anthropic(system: system, user: user, key: key)
        case .heuristic: throw VoiceError.badResponse
        }
    }

    private static func systemPrompt(style: VoiceStyle) -> String {
        let tone: String
        switch style {
        case .terse:    tone = "Be very terse — at most 8 words."
        case .standard: tone = "Keep it under about 14 words."
        case .detailed: tone = "One sentence, up to about 20 words, mentioning the key detail."
        case .playful:  tone = "Keep it light and upbeat, under about 14 words."
        }
        return "You turn a coding agent's status into ONE short spoken notification sentence. "
            + "Refer to the agent by name. No markdown, no quotes, no emoji, no file paths read "
            + "character by character. " + tone
    }

    private static func context(session: AgentSession, kind: VoiceEventKind) -> String {
        var parts = ["Agent: \(session.agent.displayName)"]
        switch kind {
        case .done:       parts.append("Event: finished its turn")
        case .permission: parts.append("Event: needs permission")
        case .question:   parts.append("Event: asking a question")
        case .plan:       parts.append("Event: shared a plan for review")
        }
        if !session.title.isEmpty { parts.append("Task: \(session.title)") }
        let activity = VoiceSummary.spoken(session.lastMessage, limit: 200)
        if !activity.isEmpty { parts.append("Latest: \(activity)") }
        if let p = session.permission {
            parts.append("Tool: \(p.toolName)")
            if let f = p.filePath, !f.isEmpty { parts.append("File: \((f as NSString).lastPathComponent)") }
        }
        if let q = session.question?.summary, !q.isEmpty { parts.append("Question: \(q)") }
        return parts.joined(separator: "\n")
    }

    private static func openAI(system: String, user: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini",
            "max_tokens": 60,
            "temperature": 0.5,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])
        let json = try await jsonObject(for: req)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw VoiceError.noContent }
        return content
    }

    private static func anthropic(system: String, user: String, key: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 60,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])
        let json = try await jsonObject(for: req)
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw VoiceError.noContent }
        return text
    }

    private static func jsonObject(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoiceError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceError.badResponse
        }
        return json
    }
}
