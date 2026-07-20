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
    private var agent: AgentKind = .unknown
    private var lastMTime: Date?
    /// Bumped on every start/stop. A parse dispatched under one generation is discarded
    /// if it lands after the tailer has moved on, so a slow read of a previous session
    /// can never overwrite the messages of the one now open.
    private var generation = 0
    private let interval: TimeInterval = 0.6
    private let onUpdate: ([ChatMessage]) -> Void

    init(onUpdate: @escaping ([ChatMessage]) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Begin tailing `url` for `agent`'s history format, delivering an initial load immediately.
    func start(url: URL, agent: AgentKind) {
        stop()
        self.url = url
        self.agent = agent
        self.lastMTime = nil
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        generation &+= 1
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
        let gen = generation
        let fileURL = url
        let agent = agent
        // Parse off the main thread — transcripts can be hundreds of KB — then hop back
        // to the main actor to deliver, dropping the result if the tailer has moved on.
        Task { [weak self] in
            let msgs = await Task.detached { ChatHistory.messages(for: agent, url: fileURL) }.value
            guard let self, self.generation == gen else { return }   // stale read
            self.onUpdate(msgs)
        }
    }
}
