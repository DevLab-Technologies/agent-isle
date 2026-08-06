import XCTest
@testable import AgentIsle

/// Contracts for `Updater.selectRelease`, the pure channel-selection logic: which release a
/// given channel picks from a list of tags/flags. Version comparison itself is covered by
/// `Updater.isNewer`; here we assert the filtering and "newest wins" behavior.
final class UpdateChannelTests: XCTestCase {

    private func r(_ tag: String, pre: Bool = false, draft: Bool = false) -> ReleaseInfo {
        ReleaseInfo(tag: tag, isPrerelease: pre, isDraft: draft)
    }

    func testStableIgnoresPreReleases() {
        let releases = [r("v1.3.0", pre: true), r("v1.2.0")]
        let chosen = Updater.selectRelease(channel: .stable, from: releases)
        XCTAssertEqual(chosen?.tag, "v1.2.0")
    }

    func testStablePicksHighestFullRelease() {
        let releases = [r("v1.1.0"), r("v1.4.0"), r("v1.2.0")]
        let chosen = Updater.selectRelease(channel: .stable, from: releases)
        XCTAssertEqual(chosen?.tag, "v1.4.0")
    }

    func testPreReleaseConsidersPreReleaseTags() {
        let releases = [r("v1.3.0", pre: true), r("v1.2.0")]
        let chosen = Updater.selectRelease(channel: .preRelease, from: releases)
        XCTAssertEqual(chosen?.tag, "v1.3.0")
    }

    func testPreReleasePrefersHigherStableOverOlderPreRelease() {
        // A newer stable should still win on the beta channel if it's the highest version.
        let releases = [r("v1.2.0-beta.1", pre: true), r("v1.5.0")]
        let chosen = Updater.selectRelease(channel: .preRelease, from: releases)
        XCTAssertEqual(chosen?.tag, "v1.5.0")
    }

    func testDraftsAreNeverSelected() {
        let stable = Updater.selectRelease(channel: .stable, from: [r("v2.0.0", draft: true), r("v1.0.0")])
        XCTAssertEqual(stable?.tag, "v1.0.0")
        let beta = Updater.selectRelease(channel: .preRelease, from: [r("v2.0.0", pre: true, draft: true), r("v1.0.0")])
        XCTAssertEqual(beta?.tag, "v1.0.0")
    }

    func testNoCandidatesReturnsNil() {
        XCTAssertNil(Updater.selectRelease(channel: .stable, from: [r("v1.0.0", pre: true)]))
        XCTAssertNil(Updater.selectRelease(channel: .preRelease, from: []))
    }

    func testCleanVersionStripsLeadingV() {
        XCTAssertEqual(r("v1.2.0").cleanVersion, "1.2.0")
        XCTAssertEqual(r("1.2.0").cleanVersion, "1.2.0")
    }

    // MARK: - Codesign Team ID parsing (updater signature gate)

    func testTeamIdentifierParsesCodesignVerboseOutput() {
        let sample = """
        Executable=/Applications/Agent Isle.app/Contents/MacOS/AgentIsle
        Identifier=com.devlab.agent-isle
        Format=app bundle with Mach-O thin (arm64)
        CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7 location=embedded
        Signature size=9000
        Authority=Developer ID Application: Example Inc (ABCD123456)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Timestamp=1 Jan 2026 at 12:00:00
        Info.plist entries=12
        TeamIdentifier=ABCD123456
        Sealed Resources version=2 rules=13 files=5
        Internal requirements count=1 size=180
        """
        XCTAssertEqual(Updater.teamIdentifier(fromCodesignOutput: sample), "ABCD123456")
    }

    func testTeamIdentifierReturnsNilWhenNotSetOrMissing() {
        XCTAssertNil(Updater.teamIdentifier(fromCodesignOutput: "Signature=adhoc\n"))
        XCTAssertNil(Updater.teamIdentifier(fromCodesignOutput: "TeamIdentifier=not set\n"))
        XCTAssertNil(Updater.teamIdentifier(fromCodesignOutput: "TeamIdentifier=\n"))
        XCTAssertEqual(
            Updater.teamIdentifier(fromCodesignOutput: "Team Identifier=XY99TEAM01\n"),
            "XY99TEAM01"
        )
    }
}
