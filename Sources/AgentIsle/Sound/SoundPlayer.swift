import AVFoundation

/// Synthesized 8-bit style event sounds — no audio files needed.
final class SoundPlayer {
    static let shared = SoundPlayer()

    var enabled = true
    /// 0…1 loudness, driven by `AppSettings.soundVolume`. Scales the wave amplitude.
    var volume: Double = 0.6

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private var started = false

    enum Event {
        case attention   // needs a decision
        case approve
        case deny
        case select
        case done

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

    func play(_ event: Event) {
        guard enabled else { return }
        ensureRunning()
        let buffer = makeBuffer(for: event.notes)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func ensureRunning() {
        guard !started else { return }
        do {
            try engine.start()
            player.play()
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
