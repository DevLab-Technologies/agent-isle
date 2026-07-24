import XCTest
@testable import AgentIsle

/// Contracts for the island's one-tap quick mute (`AppSettings.isMuted`). Mute is an
/// independent gate: it silences the sound + voice runtime channels without touching the
/// `soundEnabled`/`voiceEnabled` preferences, and unmuting resumes whatever those prefs say.
/// Banner notifications are intentionally left on.
///
/// Drives the `AppSettings.shared` singleton (private init), so each test snapshots the
/// relevant fields up front and restores them in `tearDown` to avoid leaking into the
/// tester's persisted defaults.
@MainActor
final class MuteSettingsTests: XCTestCase {

    private var savedSound = true
    private var savedVoice = false
    private var savedMuted = false
    private var savedNotifications = true

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedSound = s.soundEnabled
        savedVoice = s.voiceEnabled
        savedMuted = s.isMuted
        savedNotifications = s.notificationsEnabled
        // Start every case from a known, unmuted baseline with all channels on.
        s.isMuted = false
        s.soundEnabled = true
        s.voiceEnabled = true
        s.notificationsEnabled = true
    }

    override func tearDown() {
        let s = AppSettings.shared
        s.isMuted = savedMuted
        s.soundEnabled = savedSound
        s.voiceEnabled = savedVoice
        s.notificationsEnabled = savedNotifications
        super.tearDown()
    }

    /// Muting silences both runtime channels…
    func testMuteSilencesSoundAndVoiceChannels() {
        let s = AppSettings.shared
        s.isMuted = true
        XCTAssertTrue(s.isMuted)
        XCTAssertFalse(SoundPlayer.shared.enabled)
        XCTAssertFalse(VoiceAnnouncer.shared.enabled)
    }

    /// …without mutating the underlying preferences, so the gear-menu toggles keep showing
    /// the user's real choice.
    func testMuteLeavesPreferencesUntouched() {
        let s = AppSettings.shared
        s.isMuted = true
        XCTAssertTrue(s.soundEnabled)
        XCTAssertTrue(s.voiceEnabled)
    }

    /// Unmuting resumes exactly what the preferences say — here sound on, voice off.
    func testUnmuteResumesFromPreferences() {
        let s = AppSettings.shared
        s.soundEnabled = true
        s.voiceEnabled = false
        s.isMuted = true
        s.isMuted = false

        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(SoundPlayer.shared.enabled)    // pref was on → resumes
        XCTAssertFalse(VoiceAnnouncer.shared.enabled) // pref was off → stays off
    }

    /// A channel whose preference is off stays off even while muted (mute can only silence,
    /// never enable), and toggling a preference during a mute doesn't un-silence it.
    func testTogglingPreferenceWhileMutedStaysSilenced() {
        let s = AppSettings.shared
        s.soundEnabled = false
        s.isMuted = true
        XCTAssertFalse(SoundPlayer.shared.enabled)

        s.soundEnabled = true            // user flips it on from the gear menu…
        XCTAssertFalse(SoundPlayer.shared.enabled) // …still silenced by the active mute
        XCTAssertTrue(s.isMuted)                    // mute flag unaffected
    }

    /// Mute does not touch banner notifications — they're a separate, quieter channel.
    func testMuteLeavesNotificationsEnabled() {
        let s = AppSettings.shared
        s.notificationsEnabled = true
        s.isMuted = true
        XCTAssertTrue(Notifier.shared.enabled)
    }
}
