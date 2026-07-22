import XCTest
@testable import AgentIsle

/// Contracts for `DiagnosticsReport.render`, the pure report builder. We feed synthetic
/// inputs and assert the text includes the metadata sections and integration results, and —
/// importantly — that it carries only metadata (no session/chat content, which the builder
/// never receives).
final class DiagnosticsReportTests: XCTestCase {

    private func sampleReports() -> [IntegrationDoctor.Report] {
        [IntegrationDoctor.Report(
            agent: .claude,
            displayName: "Claude Code",
            checks: [
                IntegrationDoctor.Check(title: "CLI detected", status: .ok, detail: "Found ~/.claude"),
                IntegrationDoctor.Check(title: "Hook installed", status: .warn, detail: "Reinstall to repair."),
            ],
            fixable: true)]
    }

    private func rendered(reachable: Bool = true,
                          reports: [IntegrationDoctor.Report] = [],
                          logLines: [String] = []) -> String {
        DiagnosticsReport.render(appVersion: "1.2.3",
                                 osVersion: "15.0.0",
                                 architecture: "Apple Silicon",
                                 memoryFootprintMB: 123,
                                 serverPort: 4711,
                                 serverReachable: reachable,
                                 reports: reports,
                                 logLines: logLines,
                                 generatedAt: Date(timeIntervalSince1970: 0))
    }

    func testIncludesEnvironmentMetadata() {
        let text = rendered()
        XCTAssertTrue(text.contains("Agent Isle version: 1.2.3"))
        XCTAssertTrue(text.contains("macOS version:      15.0.0"))
        XCTAssertTrue(text.contains("Apple Silicon"))
        XCTAssertTrue(text.contains("123 MB"))
    }

    func testReportsServerReachability() {
        XCTAssertTrue(rendered(reachable: true).contains("localhost:4711: reachable"))
        XCTAssertTrue(rendered(reachable: false).contains("localhost:4711: NOT reachable"))
    }

    func testRendersIntegrationChecksWithStatusLabels() {
        let text = rendered(reports: sampleReports())
        XCTAssertTrue(text.contains("Claude Code [WARN]"))     // worst-of the checks
        XCTAssertTrue(text.contains("[OK] CLI detected"))
        XCTAssertTrue(text.contains("[WARN] Hook installed"))
    }

    func testEmptyIntegrationsAndLogsHavePlaceholders() {
        let text = rendered()
        XCTAssertTrue(text.contains("No supported CLIs detected."))
        XCTAssertTrue(text.contains("No recent log entries available."))
    }

    func testIncludesLogLinesWhenPresent() {
        let text = rendered(logLines: ["12:00:00 Updater install failed: x", "12:00:01 started"])
        XCTAssertTrue(text.contains("Updater install failed: x"))
    }

    func testDefaultFileNameIsDated() {
        let name = DiagnosticsReport.defaultFileName(date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("AgentIsle-Diagnostics-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }
}
