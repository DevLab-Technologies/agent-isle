import AVFoundation

/// Event sounds. Each cue is a synthesized 8-bit square wave by default, but the user
/// can override any event with their own audio file (see `SoundPack`).
///
/// Main-actor isolated: `enabled`/`volume`/`pack` are driven from `AppSettings` and
/// `play()` is called from the (main-actor) store, so isolation is enforced rather than
/// assumed.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    var enabled = true
    /// 0…1 loudness, driven by `AppSettings.soundVolume`. Scales the wave amplitude and
    /// the custom-file player volume.
    var volume: Double = 0.6
    /// User-provided per-event overrides; when an event has one, its file plays instead
    /// of the synthesized cue. Driven by `AppSettings.soundPack`.
    var pack = SoundPack()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var started = false
    /// The single custom-file cue currently sounding, retained so ARC can't cut it off
    /// mid-playback. Holding one (not one per event) guarantees cues never overlap.
    private var currentFile: AVAudioPlayer?
    /// A single event can arrive in a burst — several sessions surfacing the same alert
    /// in one scan tick, an event flood, or a retriggered hook. A repeat of the *same*
    /// event within this window is dropped so the burst plays one alert instead of a
    /// garbled pile-up. Distinct events never suppress each other, so a decision cue is
    /// never lost just because a different cue sounded moments earlier.
    private let coalesceWindow: TimeInterval = 0.15
    /// Per-event timestamp of the last *audible* cue (see `coalesceWindow`). Keyed by
    /// event so alerts of different kinds stay independent, and bounded by the case
    /// count. Monotonic (`DispatchTime`) so a system-clock change can't drop cues.
    private var lastPlayed: [Event: DispatchTime] = [:]

    enum Event: String, CaseIterable {
        case attention   // needs a decision
        case approve
        case deny
        case select
        case done

        /// Stable key used for persistence of custom-sound overrides.
        var key: String { rawValue }

        /// Human-readable label for the settings UI.
        var label: String {
            switch self {
            case .attention: return "Attention"
            case .approve:   return "Approve"
            case .deny:      return "Deny"
            case .select:    return "Select"
            case .done:      return "Done"
            }
        }

        /// Sequence of (frequency Hz, duration s) notes.
        var notes: [(Double, Double)] {
            switch self {
            case .attention: return [(880, 0.09), (1174, 0.11)]
            case .approve:   return [(659, 0.07), (988, 0.10)]
            case .deny:      return [(392, 0.09), (294, 0.12)]
            case .select:    return [(784, 0.06)]
            case .done:      return [(523, 0.07), (659, 0.07), (784, 0.12)]
            }
        }
    }

    private init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Plays the cue for `event`. `coalesce` collapses a burst of the *same* event into
    /// one alert; explicit, user-driven plays (e.g. the settings preview) pass `false` so
    /// they're always audible.
    func play(_ event: Event, coalesce: Bool = true) {
        guard enabled else { return }
        let now = DispatchTime.now()
        if coalesce, let last = lastPlayed[event],
           Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000 < coalesceWindow {
            return
        }

        // A new cue replaces whatever is still sounding, so cues never overlap or stack
        // into a jumble: silence any custom-file cue up front, and the synth node is
        // flushed by `.interrupts` in `playSynth` (or stopped by `playFile`).
        currentFile?.stop()
        currentFile = nil

        // Prefer the user's custom file; fall back to the synthesized cue if it can't play.
        var played = false
        if let url = pack.playableURL(for: event) { played = playFile(url, for: event) }
        if !played { played = playSynth(event.notes) }

        // Start the coalesce window only once a cue has actually sounded, so a failed or
        // silent attempt can't suppress the next real one.
        if played { lastPlayed[event] = now }
    }

    /// Plays a user-provided audio file for `event`. Returns false (so the caller falls
    /// back to the synthesized cue) if the file can't be decoded/played.
    private func playFile(_ url: URL, for event: Event) -> Bool {
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.volume = Float(max(0, min(1, volume)))
            guard audio.prepareToPlay(), audio.play() else { return false }
            if player.isPlaying { player.stop() }   // silence any synth cue underneath
            currentFile = audio                      // single retained player; no overlap
            return true
        } catch {
            NSLog("SoundPlayer: custom sound failed for \(event.key): \(error)")
            return false
        }
    }

    /// Schedules the synthesized cue, replacing any still-playing synth buffer. Owns all
    /// player-node playback state (start/restart), so the node has a single owner even
    /// after `playFile` stops it. Returns false if the audio engine won't start.
    @discardableResult
    private func playSynth(_ notes: [(Double, Double)]) -> Bool {
        ensureEngineRunning()
        guard started else { return false }
        let buffer = makeBuffer(for: notes)
        // `.interrupts` flushes any still-queued/playing synth buffer so back-to-back
        // events replace, rather than append to, the cue already sounding.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
        return true
    }

    /// Starts the audio engine once. Node playback is owned by `playSynth`, not here.
    private func ensureEngineRunning() {
        guard !started else { return }
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("SoundPlayer: audio engine failed to start: \(error)")
        }
    }

    /// Renders a square-wave (chiptune) buffer for a note sequence, with a short fade.
    private func makeBuffer(for notes: [(Double, Double)]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let totalDuration = notes.reduce(0) { $0 + $1.1 }
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let ptr = buffer.floatChannelData![0]

        // Amplitude scales with the user's volume; 0.3 keeps the default (0.6) at the
        // engine's original 0.18 loudness.
        let amp = Float(0.3 * max(0, min(1, volume)))
        var frame = 0
        for (freq, dur) in notes {
            let n = Int(dur * sampleRate)
            for i in 0..<n where frame < Int(frameCount) {
                let phase = Double(i) * freq / sampleRate
                // Square wave for the 8-bit character.
                var sample: Float = sin(2 * .pi * phase) >= 0 ? amp : -amp
                // Quick attack/decay envelope to avoid clicks.
                let env = Float(min(1.0, Double(i) / 200.0)) * Float(min(1.0, Double(n - i) / 400.0))
                sample *= env
                ptr[frame] = sample
                frame += 1
            }
        }
        return buffer
    }
}
