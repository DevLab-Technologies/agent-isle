import AVFoundation
import Foundation

/// Speaks short callouts when an agent finishes or needs attention — the spoken companion to
/// `SoundPlayer`'s chiptune cues. Two tiers, both driven by `VoiceConfig`:
///
///   • **On-device (default).** `AVSpeechSynthesizer` reads a line composed locally by
///     `VoiceSummary`. Free, offline, nothing leaves the machine — Agent Isle's "fully
///     local" promise is intact.
///   • **Bring-your-own-key (opt-in).** With a cloud provider selected and the user's own API
///     key present, the line is (optionally) phrased by a small LLM and spoken by a cloud TTS
///     voice. The user pays their provider directly; Agent Isle runs no backend.
///
/// Announcements are serialized through a task chain so callouts never talk over each other,
/// and a cloud failure always falls back to the local voice so the user still hears something.
///
/// Main-actor isolated: `enabled`/`config`/keys are pushed from `AppSettings` (which folds the
/// enabled gate through `applyMuting`, same as `SoundPlayer`), and `announce` is called from
/// the main-actor event server / watcher.
@MainActor
final class VoiceAnnouncer: NSObject {
    static let shared = VoiceAnnouncer()

    /// Master gate, AND-ed by `AppSettings.applyMuting` with "no quiet scene active".
    var enabled = false
    var config = VoiceConfig()
    /// Resolved from the Keychain by `AppSettings` so this class never reads storage itself.
    var openAIKey: String?
    var elevenLabsKey: String?
    var anthropicKey: String?

    private let synthesizer = AVSpeechSynthesizer()
    /// Serial tail: each announcement awaits the previous one, so utterances never overlap.
    private var tail: Task<Void, Never> = Task {}

    // Playback bookkeeping. Only one cloud clip plays at a time (the queue guarantees it).
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    /// Bumped each time a clip finishes, so a previous clip's duration watchdog can't cut off
    /// the next one it happens to fire during.
    private var playbackGeneration = 0
    private var speechContinuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public entry points

    /// Announce a session moment. Returns immediately; the work is enqueued so callers (the
    /// event server, the watcher) never block on speech synthesis or the network.
    func announce(session: AgentSession, kind: VoiceEventKind) {
        guard enabled, config.shouldAnnounce(kind) else { return }
        enqueue(session: session, kind: kind, force: false)
    }

    /// Speak a sample line for the settings preview, bypassing the enabled / announce-on gates
    /// (but honoring the chosen provider, style, and per-agent voice).
    func preview(agent: AgentKind = .claude) {
        let sample = AgentSession(agent: agent,
                                  title: "fix auth bug",
                                  terminal: "iTerm",
                                  lastMessage: "Updated middleware.ts (+3 -1)",
                                  status: .done)
        enqueue(session: sample, kind: .done, force: true)
    }

    /// Stop anything currently speaking or playing (e.g. when the user disables voice).
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        finishPlayback()
    }

    // MARK: - Queue

    private func enqueue(session: AgentSession, kind: VoiceEventKind, force: Bool) {
        let prev = tail
        tail = Task { @MainActor [weak self] in
            await prev.value
            guard let self, force || self.enabled else { return }
            let text = await self.composeLine(session: session, kind: kind)
            let spoken = VoiceSummary.spoken(text)
            guard !spoken.isEmpty else { return }
            await self.speak(spoken, agent: session.agent)
        }
    }

    // MARK: - Line composition

    /// The heuristic line is always the baseline; a cloud summary, when enabled and it
    /// succeeds, replaces it. Any failure silently keeps the local line.
    private func composeLine(session: AgentSession, kind: VoiceEventKind) async -> String {
        let local = VoiceSummary.line(for: session, kind: kind, style: config.style)
        guard config.summaryProvider.isCloud else { return local }
        guard let key = key(for: config.summaryProvider.keyAccount), !key.isEmpty else { return local }
        do {
            let ai = try await SummaryClient.summarize(session: session, kind: kind,
                                                       style: config.style,
                                                       provider: config.summaryProvider, key: key)
            let trimmed = ai.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? local : trimmed
        } catch {
            NSLog("VoiceAnnouncer: summary provider failed, using local line: \(error.localizedDescription)")
            return local
        }
    }

    // MARK: - Speaking

    private func speak(_ text: String, agent: AgentKind) async {
        if config.provider.isCloud, let key = key(for: config.provider.keyAccount), !key.isEmpty {
            do {
                let data = try await SpeechClient.synthesize(text: text, agent: agent,
                                                             config: config, key: key)
                await playData(data)
                return
            } catch {
                NSLog("VoiceAnnouncer: cloud TTS failed, falling back to on-device: \(error.localizedDescription)")
                // fall through to the local voice
            }
        }
        await speakLocal(text, agent: agent)
    }

    private func speakLocal(_ text: String, agent: AgentKind) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = localVoice(for: agent)
        utterance.volume = Float(max(0, min(1, config.volume)))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = ObjectIdentifier(utterance)
            speechContinuations[id] = cont
            synthesizer.speak(utterance)
            // Watchdog: if a delegate callback never arrives, don't stall the queue forever.
            let words = max(1, text.split(separator: " ").count)
            let cap = min(45.0, Double(words) * 0.7 + 5.0)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                self?.resumeSpeech(id)
            }
        }
    }

    private func playData(_ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Assign first so every early exit — a throwing `AVAudioPlayer(data:)`, a failed
            // `play()`, or normal completion — resumes this continuation exactly once. Setting
            // it only after the throwing init would let the catch resume nil and wedge the queue.
            playbackContinuation = cont
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.volume = Float(max(0, min(1, config.volume)))
                audioPlayer = player
                guard player.prepareToPlay(), player.play() else {
                    finishPlayback(); return
                }
                let generation = playbackGeneration
                let cap = player.duration + 3.0
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
                    self?.finishPlayback(generation: generation)
                }
            } catch {
                NSLog("VoiceAnnouncer: could not play synthesized audio: \(error.localizedDescription)")
                finishPlayback()
            }
        }
    }

    // MARK: - Voice selection

    /// Installed English voices, best quality first, in a stable order (so the per-agent
    /// mapping is deterministic across launches). Computed once.
    private lazy var englishVoices: [AVSpeechSynthesisVoice] = {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue
                    ? a.quality.rawValue > b.quality.rawValue
                    : a.identifier < b.identifier
            }
    }()

    /// A distinct-but-stable voice per agent, or the system default when the option is off or
    /// no voices are installed.
    private func localVoice(for agent: AgentKind) -> AVSpeechSynthesisVoice? {
        guard config.distinctVoicePerAgent, !englishVoices.isEmpty else {
            return AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        }
        let idx = stableIndex(agent.rawValue, count: englishVoices.count)
        return englishVoices[idx]
    }

    // MARK: - Helpers

    private func key(for account: String?) -> String? {
        switch account {
        case Keychain.Account.openAIKey:     return openAIKey
        case Keychain.Account.elevenLabsKey: return elevenLabsKey
        case Keychain.Account.anthropicKey:  return anthropicKey
        default:                             return nil
        }
    }

    private func resumeSpeech(_ id: ObjectIdentifier) {
        speechContinuations.removeValue(forKey: id)?.resume()
    }

    /// Resume the in-flight playback wait. The optional `generation` guards a stale watchdog:
    /// it only acts when the clip it was scheduled for is still the current one.
    private func finishPlayback(generation: Int? = nil) {
        if let generation, generation != playbackGeneration { return }
        playbackGeneration &+= 1
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
    }
}

// MARK: - Delegates

extension VoiceAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.resumeSpeech(ObjectIdentifier(utterance)) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.resumeSpeech(ObjectIdentifier(utterance)) }
    }
}

extension VoiceAnnouncer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }
}
