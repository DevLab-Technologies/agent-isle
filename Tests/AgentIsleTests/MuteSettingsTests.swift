import XCTest
@testable import AgentIsle

/// Contracts for the island's one-tap quick mute (`AppSettings.setMuted`): muting turns
/// both sound and voice off while snapshotting their prior state, unmuting restores exactly
/// what was on, and re-enabling either switch individually drops the flag.
///
/// Drives the `AppSettings.shared` singleton (private init), so each test snapshots the
/// relevant fields up front and restores them in `tearDown` to avoid leaking into the
/// tester's persisted defaults.
@MainActor
final class MuteSettingsTests: XCTestCase {

    private var savedSound = true
    private var savedVoice = false
    private var savedMuted = false

    override func setUp() {
        super.setUp()
        let s = AppSettings.shared
        savedSound = s.soundEnabled
        savedVoice = s.voiceEnabled
        savedMuted = s.isMuted
        // Start every case from a known, unmuted baseline.
        if s.isMuted { s.setMuted(false) }
        s.soundEnabled = true
        s.voiceEnabled = true
    }

    override func tearDown() {
        let s = AppSettings.shared
        if s.isMuted { s.setMuted(false) }
        s.soundEnabled = savedSound
        s.voiceEnabled = savedVoice
        if s.isMuted != savedMuted { s.setMuted(savedMuted) }
        super.tearDown()
    }

    /// Muting silences both switches and flips the flag.
    func testMuteSilencesSoundAndVoice() {
        let s = AppSettings.shared
        s.setMuted(true)
        XCTAssertTrue(s.isMuted)
        XCTAssertFalse(s.soundEnabled)
        XCTAssertFalse(s.voiceEnabled)
    }

    /// Unmuting restores exactly what was on before the mute.
    func testUnmuteRestoresPriorState() {
        let s = AppSettings.shared
        s.soundEnabled = true
        s.voiceEnabled = false
        s.setMuted(true)
        XCTAssertFalse(s.soundEnabled)
        XCTAssertFalse(s.voiceEnabled)

        s.setMuted(false)
        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(s.soundEnabled)   // restored on
        XCTAssertFalse(s.voiceEnabled)  // restored off
    }

    /// A mute captured with both switches off restores both to off (not the defaults).
    func testUnmuteRestoresBothOff() {
        let s = AppSettings.shared
        s.soundEnabled = false
        s.voiceEnabled = false
        s.setMuted(true)
        s.setMuted(false)
        XCTAssertFalse(s.soundEnabled)
        XCTAssertFalse(s.voiceEnabled)
    }

    /// Re-enabling sound individually while muted drops the flag (the island is no longer
    /// fully silenced), leaving the other switch untouched.
    func testReenablingSoundClearsMute() {
        let s = AppSettings.shared
        s.setMuted(true)
        XCTAssertTrue(s.isMuted)

        s.soundEnabled = true
        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(s.soundEnabled)
        XCTAssertFalse(s.voiceEnabled)
    }

    /// Same for re-enabling voice individually.
    func testReenablingVoiceClearsMute() {
        let s = AppSettings.shared
        s.setMuted(true)
        s.voiceEnabled = true
        XCTAssertFalse(s.isMuted)
        XCTAssertTrue(s.voiceEnabled)
    }

    /// `setMuted` guards on a no-op transition, so calling it with the current value must not
    /// re-snapshot and clobber the remembered pre-mute state.
    func testRedundantMuteDoesNotClobberSnapshot() {
        let s = AppSettings.shared
        s.soundEnabled = true
        s.voiceEnabled = false
        s.setMuted(true)
        // A second mute-true is a no-op; if it re-snapshotted it would capture the now-false
        // states and unmute would wrongly restore both to off.
        s.setMuted(true)
        s.setMuted(false)
        XCTAssertTrue(s.soundEnabled)
        XCTAssertFalse(s.voiceEnabled)
    }
}
