import XCTest
@testable import AgentIsle

/// Contracts for the pure event→file resolution used by custom sound packs.
final class SoundPackTests: XCTestCase {

    // MARK: - Empty pack (no overrides)

    func testEmptyPackHasNoOverrides() {
        let pack = SoundPack()
        for event in SoundPlayer.Event.allCases {
            XCTAssertNil(pack.url(for: event))
            XCTAssertFalse(pack.hasOverride(for: event))
            XCTAssertNil(pack.playableURL(for: event))
        }
    }

    // MARK: - Set / clear resolution

    func testSetOverrideResolvesToURL() {
        var pack = SoundPack()
        let url = URL(fileURLWithPath: "/tmp/attention.wav")
        pack.set(url, for: .attention)

        XCTAssertTrue(pack.hasOverride(for: .attention))
        XCTAssertEqual(pack.url(for: .attention), url)
        // Other events are unaffected.
        XCTAssertNil(pack.url(for: .approve))
        XCTAssertFalse(pack.hasOverride(for: .approve))
    }

    func testClearOverrideRemovesIt() {
        var pack = SoundPack()
        pack.set(URL(fileURLWithPath: "/tmp/done.mp3"), for: .done)
        XCTAssertTrue(pack.hasOverride(for: .done))

        pack.set(nil, for: .done)
        XCTAssertFalse(pack.hasOverride(for: .done))
        XCTAssertNil(pack.url(for: .done))
    }

    func testOverridesAreIndependentPerEvent() {
        var pack = SoundPack()
        let approve = URL(fileURLWithPath: "/tmp/approve.aiff")
        let deny = URL(fileURLWithPath: "/tmp/deny.aiff")
        pack.set(approve, for: .approve)
        pack.set(deny, for: .deny)

        XCTAssertEqual(pack.url(for: .approve), approve)
        XCTAssertEqual(pack.url(for: .deny), deny)

        pack.set(nil, for: .approve)
        XCTAssertNil(pack.url(for: .approve))
        XCTAssertEqual(pack.url(for: .deny), deny)   // clearing one leaves the other
    }

    // MARK: - playableURL checks file existence (fall back when missing)

    func testPlayableURLNilWhenFileMissing() {
        var pack = SoundPack()
        pack.set(URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav"),
                 for: .select)
        // Override is configured, but the file is gone -> fall back to the synthesized cue.
        XCTAssertTrue(pack.hasOverride(for: .select))
        XCTAssertNil(pack.playableURL(for: .select))
    }

    func testPlayableURLReturnsExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("agent-isle-cue-\(UUID().uuidString).wav")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var pack = SoundPack()
        pack.set(file, for: .approve)
        XCTAssertEqual(pack.playableURL(for: .approve), file)
    }

    // MARK: - Empty-path guards

    func testEmptyPathIsNotAnOverride() {
        let pack = SoundPack(overrides: ["attention": ""])
        XCTAssertFalse(pack.hasOverride(for: .attention))
        XCTAssertNil(pack.url(for: .attention))
    }

    // MARK: - Persistence round-trip (event key -> path map)

    func testOverridesRoundTripThroughJSON() throws {
        var pack = SoundPack()
        pack.set(URL(fileURLWithPath: "/tmp/a.wav"), for: .attention)
        pack.set(URL(fileURLWithPath: "/tmp/d.mp3"), for: .done)

        let data = try JSONEncoder().encode(pack.overrides)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        let restored = SoundPack(overrides: decoded)

        XCTAssertEqual(restored, pack)
        XCTAssertEqual(restored.url(for: .attention), URL(fileURLWithPath: "/tmp/a.wav"))
        XCTAssertEqual(restored.url(for: .done), URL(fileURLWithPath: "/tmp/d.mp3"))
    }

    // MARK: - Event keys are stable (persistence depends on them)

    func testEventKeysAreStable() {
        XCTAssertEqual(SoundPlayer.Event.attention.key, "attention")
        XCTAssertEqual(SoundPlayer.Event.approve.key, "approve")
        XCTAssertEqual(SoundPlayer.Event.deny.key, "deny")
        XCTAssertEqual(SoundPlayer.Event.select.key, "select")
        XCTAssertEqual(SoundPlayer.Event.done.key, "done")
    }

    // MARK: - Supported file types

    func testSupportedFileDetection() {
        XCTAssertTrue(SoundPack.isSupportedFile(URL(fileURLWithPath: "/x/cue.wav")))
        XCTAssertTrue(SoundPack.isSupportedFile(URL(fileURLWithPath: "/x/cue.AIFF")))
        XCTAssertTrue(SoundPack.isSupportedFile(URL(fileURLWithPath: "/x/cue.mp3")))
        XCTAssertFalse(SoundPack.isSupportedFile(URL(fileURLWithPath: "/x/cue.txt")))
        XCTAssertFalse(SoundPack.isSupportedFile(URL(fileURLWithPath: "/x/cue")))
    }
}
