import Foundation

/// A user's custom sound overrides: a map from a `SoundPlayer.Event` to an audio file
/// on disk. Pure value type — persistence lives in `AppSettings`, playback in
/// `SoundPlayer` — so the event→file resolution is unit-testable in isolation.
///
/// Overrides are stored as absolute file paths keyed by the event's stable `key`.
struct SoundPack: Equatable {
    /// Event key -> absolute file path. Kept as a plain dictionary so it round-trips
    /// through `UserDefaults`/JSON without a custom coder.
    private(set) var overrides: [String: String]

    init(overrides: [String: String] = [:]) {
        self.overrides = overrides
    }

    /// The override file URL for `event`, or nil when the event uses the synthesized cue.
    /// Does not check whether the file still exists — see `playableURL(for:)`.
    func url(for event: SoundPlayer.Event) -> URL? {
        guard let path = overrides[event.key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when `event` has a custom override configured (regardless of file existence).
    func hasOverride(for event: SoundPlayer.Event) -> Bool {
        guard let path = overrides[event.key] else { return false }
        return !path.isEmpty
    }

    /// The override URL to actually play: an override that still exists on disk. Returns
    /// nil (fall back to the synthesized cue) when there's no override or the file is gone.
    func playableURL(for event: SoundPlayer.Event) -> URL? {
        guard let url = url(for: event),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Sets (or, with `nil`, clears) the override for `event`.
    mutating func set(_ url: URL?, for event: SoundPlayer.Event) {
        if let url {
            overrides[event.key] = url.path
        } else {
            overrides.removeValue(forKey: event.key)
        }
    }

    /// Audio extensions accepted for custom cues.
    static let allowedExtensions: Set<String> = ["wav", "aiff", "aif", "mp3"]

    /// Whether `url` looks like an accepted audio file by extension.
    static func isSupportedFile(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }
}
