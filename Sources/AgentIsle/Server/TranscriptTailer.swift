import Foundation

/// Watches a single session's transcript and republishes its parsed messages whenever
/// the file changes, so the open chat view stays live.
///
/// Uses a short mtime-poll (the transcript is append-only, written continuously while a
/// session works) rather than FSEvents — it matches the rest of the app's polling style
/// and only runs while a chat is actually open.
@MainActor
final class TranscriptTailer {
    private var timer: Timer?
    private var url: URL?
    private var lastMTime: Date?
    private let interval: TimeInterval = 0.6
    private let onUpdate: ([ChatMessage]) -> Void

    init(onUpdate: @escaping ([ChatMessage]) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Begin tailing `url`, delivering an initial load immediately.
    func start(url: URL) {
        stop()
        self.url = url
        self.lastMTime = nil
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        url = nil
        lastMTime = nil
    }

    private func tick() {
        guard let url else { return }
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let last = lastMTime, last == m { return }   // nothing new
        lastMTime = m
        // Parse off the main thread — transcripts can be hundreds of KB.
        Task.detached { [onUpdate] in
            let msgs = TranscriptReader.messages(in: url)
            await MainActor.run { onUpdate(msgs) }
        }
    }
}
