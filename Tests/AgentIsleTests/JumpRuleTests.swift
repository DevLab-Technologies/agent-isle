import XCTest
@testable import AgentIsle

/// Contracts for custom jump-rule matching and URL-scheme path substitution (pure logic).
final class JumpRuleTests: XCTestCase {

    private func session(terminal: String = "Ghostty",
                         terminalBundleID: String? = nil,
                         workspacePath: String? = nil) -> AgentSession {
        AgentSession(agent: .claude, title: "fix auth", terminal: terminal,
                     lastMessage: "", status: .working,
                     workspacePath: workspacePath, terminalBundleID: terminalBundleID)
    }

    // MARK: - Matching

    func testTerminalNameMatchesCaseInsensitively() {
        let rule = JumpRule(field: .terminalName, matchValue: "ghostty",
                            strategy: .activateBundle, strategyValue: "com.mitchellh.ghostty")
        XCTAssertTrue(rule.matches(session(terminal: "Ghostty")))
        XCTAssertFalse(rule.matches(session(terminal: "iTerm")))
    }

    func testBundleIDMatchesCaseInsensitivelyAndExactly() {
        let rule = JumpRule(field: .terminalBundleID, matchValue: "com.mitchellh.ghostty",
                            strategy: .activateBundle, strategyValue: "com.mitchellh.ghostty")
        XCTAssertTrue(rule.matches(session(terminalBundleID: "com.mitchellh.Ghostty")))
        XCTAssertFalse(rule.matches(session(terminalBundleID: "com.mitchellh")))
    }

    func testBundleRuleIgnoresSessionsWithoutBundle() {
        let rule = JumpRule(field: .terminalBundleID, matchValue: "com.apple.Terminal",
                            strategy: .activateBundle, strategyValue: "com.apple.Terminal")
        XCTAssertFalse(rule.matches(session(terminalBundleID: nil)))
    }

    func testDisabledRuleNeverMatches() {
        var rule = JumpRule(field: .terminalName, matchValue: "Ghostty",
                            strategy: .activateBundle, strategyValue: "x")
        rule.enabled = false
        XCTAssertFalse(rule.matches(session(terminal: "Ghostty")))
    }

    func testEmptyMatchValueNeverMatches() {
        let rule = JumpRule(field: .terminalName, matchValue: "   ",
                            strategy: .activateBundle, strategyValue: "x")
        XCTAssertFalse(rule.matches(session(terminal: "Ghostty")))
    }

    // MARK: - URL-scheme substitution (pure logic)

    func testSubstituteReplacesPathToken() {
        let out = JumpRule.substitute(template: "x-myeditor://open?path={path}",
                                      path: "/Users/me/proj")
        XCTAssertEqual(out, "x-myeditor://open?path=/Users/me/proj")
    }

    func testSubstitutePercentEncodesSpaces() {
        let out = JumpRule.substitute(template: "x-myeditor://open?path={path}",
                                      path: "/Users/me/My Project")
        XCTAssertEqual(out, "x-myeditor://open?path=/Users/me/My%20Project")
    }

    func testSubstituteWithoutTokenReturnsTemplateUnchanged() {
        let out = JumpRule.substitute(template: "myapp://home", path: "/Users/me/proj")
        XCTAssertEqual(out, "myapp://home")
    }

    func testSubstituteTrimsWhitespace() {
        let out = JumpRule.substitute(template: "  myapp://home  ", path: nil)
        XCTAssertEqual(out, "myapp://home")
    }

    func testSubstituteReturnsNilWhenTokenNeedsMissingPath() {
        XCTAssertNil(JumpRule.substitute(template: "x://open?path={path}", path: nil))
        XCTAssertNil(JumpRule.substitute(template: "x://open?path={path}", path: ""))
    }

    func testSubstituteReturnsNilForEmptyTemplate() {
        XCTAssertNil(JumpRule.substitute(template: "   ", path: "/Users/me/proj"))
    }

    // MARK: - resolvedURL

    func testResolvedURLBuildsURLWithSubstitutedPath() {
        let rule = JumpRule(field: .terminalName, matchValue: "Ghostty",
                            strategy: .openURL, strategyValue: "vscode://file{path}")
        let url = rule.resolvedURL(workspacePath: "/Users/me/proj")
        XCTAssertEqual(url?.absoluteString, "vscode://file/Users/me/proj")
    }

    func testResolvedURLNilForActivateBundleStrategy() {
        let rule = JumpRule(field: .terminalName, matchValue: "Ghostty",
                            strategy: .activateBundle, strategyValue: "com.mitchellh.ghostty")
        XCTAssertNil(rule.resolvedURL(workspacePath: "/Users/me/proj"))
    }

    func testResolvedURLNilWhenPathMissing() {
        let rule = JumpRule(field: .terminalName, matchValue: "Ghostty",
                            strategy: .openURL, strategyValue: "vscode://file{path}")
        XCTAssertNil(rule.resolvedURL(workspacePath: nil))
    }

    // MARK: - activationBundleID

    func testActivationBundleIDTrimsAndGatesOnStrategy() {
        let activate = JumpRule(field: .terminalName, matchValue: "Ghostty",
                                strategy: .activateBundle, strategyValue: "  com.apple.Terminal  ")
        XCTAssertEqual(activate.activationBundleID, "com.apple.Terminal")

        let openURL = JumpRule(field: .terminalName, matchValue: "Ghostty",
                               strategy: .openURL, strategyValue: "x://y")
        XCTAssertNil(openURL.activationBundleID)

        let empty = JumpRule(field: .terminalName, matchValue: "Ghostty",
                             strategy: .activateBundle, strategyValue: "   ")
        XCTAssertNil(empty.activationBundleID)
    }

    // MARK: - Persistence

    func testRuleRoundTripsThroughJSON() throws {
        let rules = [
            JumpRule(field: .terminalName, matchValue: "Ghostty",
                     strategy: .openURL, strategyValue: "vscode://file{path}"),
            JumpRule(field: .terminalBundleID, matchValue: "com.apple.Terminal",
                     strategy: .activateBundle, strategyValue: "com.apple.Terminal", enabled: false),
        ]
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([JumpRule].self, from: data)
        XCTAssertEqual(decoded, rules)
    }

    func testLoadSaveAndFirstMatchThroughDefaults() {
        let suite = "JumpRuleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(JumpRule.load(from: defaults).isEmpty)

        let rules = [
            JumpRule(field: .terminalName, matchValue: "iTerm",
                     strategy: .activateBundle, strategyValue: "com.googlecode.iterm2", enabled: false),
            JumpRule(field: .terminalName, matchValue: "Ghostty",
                     strategy: .activateBundle, strategyValue: "com.mitchellh.ghostty"),
        ]
        JumpRule.save(rules, to: defaults)
        XCTAssertEqual(JumpRule.load(from: defaults), rules)

        // Disabled iTerm rule is skipped; first enabled match is the Ghostty rule.
        let match = JumpRule.firstMatch(for: session(terminal: "Ghostty"), in: defaults)
        XCTAssertEqual(match?.strategyValue, "com.mitchellh.ghostty")

        // No match for an unlisted terminal.
        XCTAssertNil(JumpRule.firstMatch(for: session(terminal: "Kitty"), in: defaults))
    }
}
