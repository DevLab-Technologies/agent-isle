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
    /// Monotonic id per enqueued announcement, and the latest id seen per session. Used to drop
    /// a queued callout that a newer one for the same session has superseded while it waited.
    private var announceSeq = 0
    private var latestSeqBySession: [UUID: Int] = [:]
    /// A callout that has waited longer than this in the queue (e.g. behind a slow cloud
    /// request or a burst) is stale — skip it rather than read out old news.
    private let maxQueueAge: TimeInterval = 20

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
        announceSeq &+= 1
        let seq = announceSeq
        // Previews use a throwaway session; don't let them participate in supersede tracking.
        if !force { latestSeqBySession[session.id] = seq }
        let enqueuedAt = Date()
        let prev = tail
        tail = Task { @MainActor [weak self] in
            await prev.value
            guard let self, force || self.enabled else { return }
            if !force {
                // Drop if a newer callout for this session superseded this one while it waited,
                // or if it sat in the queue long enough to be stale (behind a slow request).
                if self.latestSeqBySession[session.id] != seq { return }
                self.latestSeqBySession[session.id] = nil
                guard Date().timeIntervalSince(enqueuedAt) <= self.maxQueueAge else { return }
            }
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

    /// Natural-sounding installed voices, best first (see `SystemVoiceCatalog`). Computed once;
    /// used both as the auto-distinct pool and as the automatic fallback.
    private lazy var naturalVoices: [AVSpeechSynthesisVoice] = SystemVoiceCatalog.naturalVoices()

    /// Resolve the on-device voice for `agent`, in priority order:
    ///   1. an explicit per-agent choice the user picked,
    ///   2. an auto-assigned distinct voice (when that option is on),
    ///   3. the user's chosen default voice,
    ///   4. the single best natural voice — and only then the system language default.
    /// A stored identifier that is no longer installed resolves to nil and falls through.
    private func localVoice(for agent: AgentKind) -> AVSpeechSynthesisVoice? {
        if let id = config.perAgentVoice[agent.rawValue], !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        let pool = naturalVoices
        if config.distinctVoicePerAgent, pool.count > 1 {
            return pool[stableIndex(agent.rawValue, count: pool.count)]
        }
        if !config.defaultVoiceId.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: config.defaultVoiceId) {
            return voice
        }
        return pool.first ?? AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
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

// MARK: - System voice catalog

/// One selectable on-device voice, for the settings pickers.
struct SystemVoiceOption: Identifiable, Hashable {
    /// `AVSpeechSynthesisVoice.identifier`, persisted so a choice survives relaunches.
    let id: String
    /// Human label, e.g. "Samantha — US" or "Zoe — US · Premium".
    let label: String
}

/// The curated list of natural on-device voices, shared by `VoiceAnnouncer` (as its pool and
/// fallback) and the settings pickers so both agree on exactly which voices are offered.
///
/// The system ships a pile of robotic joke voices (Zarvox, Bells, Bad News, Trinoids…) and the
/// dated DECtalk-style Eloquence set alongside the modern natural voices. All report `.default`
/// quality, so a plain quality sort can't separate them — offering the whole list is what made
/// callouts sound terrible. We keep only the natural voices, and any Enhanced/Premium voice the
/// user has downloaded floats to the top since it genuinely sounds best.
enum SystemVoiceCatalog {
    /// Excludes the novelty voices (`…speech.synthesis.voice.*`, e.g. Zarvox, Fred, Albert) and
    /// the old robotic Eloquence set (`…eloquence.*`), keeping the modern natural voices
    /// (`com.apple.voice.*`, Siri) plus anything already at Enhanced/Premium quality.
    static func isNatural(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.quality != .default { return true }
        let id = voice.identifier
        return !id.contains(".speech.synthesis.voice.") && !id.contains(".eloquence.")
    }

    /// Installed English natural voices, best quality first, in a stable order.
    static func naturalVoices() -> [AVSpeechSynthesisVoice] {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let natural = english.filter(isNatural)
        // Never end up with nothing: if the user somehow has only novelty voices, use them all.
        return (natural.isEmpty ? english : natural).sorted { a, b in
            a.quality.rawValue != b.quality.rawValue
                ? a.quality.rawValue > b.quality.rawValue
                : a.identifier < b.identifier
        }
    }

    /// The picker options for the natural voices.
    static func options() -> [SystemVoiceOption] {
        naturalVoices().map { SystemVoiceOption(id: $0.identifier, label: label(for: $0)) }
    }

    /// "Samantha — US", or "Zoe — US · Enhanced" when the voice is a downloaded higher tier.
    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let region = voice.language.split(separator: "-").last.map(String.init) ?? voice.language
        var label = "\(voice.name) — \(region)"
        switch voice.quality {
        case .premium:  label += " · Premium"
        case .enhanced: label += " · Enhanced"
        default:        break
        }
        return label
    }
}
