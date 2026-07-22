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
}
