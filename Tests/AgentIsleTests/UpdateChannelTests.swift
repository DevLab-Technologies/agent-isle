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

    // MARK: - Signature gate

    func testVerifyRejectsUnsignedPath() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-isle-unsigned-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            try await Updater.verifyUpdateCandidate(dir)
            XCTFail("unsigned path should fail the signature gate")
        } catch UpdateError.invalidSignature {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVerifyRejectsAdHocBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-isle-adhoc-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Evil.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exe = macOS.appendingPathComponent("Evil")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "ad-hoc codesign should succeed")

        do {
            try await Updater.verifyUpdateCandidate(app)
            XCTFail("ad-hoc bundle must not pass the pinned Team ID requirement")
        } catch UpdateError.invalidSignature {
            // expected — this is the #42 attack (compromised zip, ad-hoc signed)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
