import XCTest
@testable import AgentIsle

/// Contracts for the GitHub new-issue URL builder. `issueURL` is a pure function, so we
/// assemble a URL and parse it back with `URLComponents` to assert the query items decode
/// to the intended values. The important guard is encoding of the query sub-delimiters
/// (`&`, `+`, `=`, `#`) that `URLComponents.queryItems` would otherwise leave literal and
/// corrupt the title/body — plus the length cap that keeps the URL under GitHub's limit.
final class ReportProblemTests: XCTestCase {

    /// Decode the query items of a built issue URL back into a `[name: value]` map.
    private func queryItems(title: String, details: String) throws -> [String: String] {
        let url = try XCTUnwrap(ProblemReport.issueURL(title: title, details: details))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "github.com")
        XCTAssertEqual(comps.path, "/DevLab-Technologies/agent-isle/issues/new")
        return Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testTitleGetsBugPrefixAndLabel() throws {
        let items = try queryItems(title: "Notch misaligned", details: "")
        XCTAssertEqual(items["title"], "[bug] Notch misaligned")
        XCTAssertEqual(items["labels"], "bug")
    }

    func testAmpersandInTitleSurvivesRoundTrip() throws {
        // The URLComponents footgun: an unescaped `&` would split the query and truncate
        // the title. Parsing back must yield the full title, and the details must not leak
        // into a stray parameter.
        let items = try queryItems(title: "Crash on drag & drop", details: "")
        XCTAssertEqual(items["title"], "[bug] Crash on drag & drop")
    }

    func testPlusAndEqualsAndHashInTitleSurvive() throws {
        // `+` must not become a space, `=` must not split a key/value, `#` must not start
        // a fragment.
        let items = try queryItems(title: "C++ x=1 #42 fails", details: "")
        XCTAssertEqual(items["title"], "[bug] C++ x=1 #42 fails")
    }

    func testDetailsEmbeddedInBodyWithEnvironment() throws {
        let items = try queryItems(title: "T", details: "Steps to reproduce")
        let body = try XCTUnwrap(items["body"])
        XCTAssertTrue(body.contains("**What happened**"))
        XCTAssertTrue(body.contains("Steps to reproduce"))
        XCTAssertTrue(body.contains("**Environment**"))
        XCTAssertTrue(body.contains("Agent Isle version:"))
    }

    func testEmptyDetailsUsesPlaceholder() throws {
        let items = try queryItems(title: "T", details: "   ")
        let body = try XCTUnwrap(items["body"])
        XCTAssertTrue(body.contains("_Describe the problem._"))
    }

    func testDetailsAreCappedAtMaxLength() throws {
        let long = String(repeating: "x", count: ProblemReport.maxDetailsLength + 500)
        let items = try queryItems(title: "T", details: long)
        let body = try XCTUnwrap(items["body"])
        let runOfX = body.filter { $0 == "x" }.count
        XCTAssertEqual(runOfX, ProblemReport.maxDetailsLength, "description is truncated to the cap")
    }

    func testTitleAndDetailsAreTrimmed() throws {
        let items = try queryItems(title: "  spaced  ", details: "  body text  ")
        XCTAssertEqual(items["title"], "[bug] spaced")
        let body = try XCTUnwrap(items["body"])
        XCTAssertTrue(body.contains("body text"))
        XCTAssertFalse(body.contains("  body text  "))
    }
}
