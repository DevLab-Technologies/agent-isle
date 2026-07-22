import XCTest
@testable import AgentIsle

/// Contracts for the usage scanner: it sums fresh tokens per session-day (input + output
/// + cache-creation, excluding cache reads), derives the project from `cwd`, and splits a
/// session that spans midnight into one record per day.
final class UsageAnalyticsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentisle-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSumsTokensAndDerivesProject() throws {
        let lines = [
            usageLine(day: "2026-07-01", input: 100, output: 50, cacheCreate: 10, cacheRead: 999, cwd: "/Users/me/app"),
            usageLine(day: "2026-07-01", input: 5, output: 5, cacheCreate: 0, cacheRead: 0, cwd: "/Users/me/app"),
        ]
        let url = try write(lines, name: "sess1.jsonl")

        let records = UsageAnalytics.scanFile(url, folderName: "-Users-me-app")
        XCTAssertEqual(records.count, 1, "same day collapses to one record")
        let r = records[0]
        XCTAssertEqual(r.project, "app")
        XCTAssertEqual(r.sessionID, "sess1")
        // 160 + 10 = 170; cache *reads* (999) excluded.
        XCTAssertEqual(r.tokens, 170)
        XCTAssertEqual(r.messages, 2)
    }

    func testSplitsAcrossDays() throws {
        let lines = [
            usageLine(day: "2026-07-01", input: 100, output: 0, cacheCreate: 0, cacheRead: 0, cwd: "/Users/me/app"),
            usageLine(day: "2026-07-02", input: 40, output: 0, cacheCreate: 0, cacheRead: 0, cwd: "/Users/me/app"),
        ]
        let url = try write(lines, name: "sess2.jsonl")

        let records = UsageAnalytics.scanFile(url, folderName: "-Users-me-app")
            .sorted { $0.day < $1.day }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.tokens), [100, 40])
    }

    func testIgnoresLinesWithoutUsage() throws {
        let lines = [
            #"{"type":"user","message":{"content":"hi"},"timestamp":"2026-07-01T10:00:00.000Z","cwd":"/Users/me/app"}"#,
            usageLine(day: "2026-07-01", input: 7, output: 0, cacheCreate: 0, cacheRead: 0, cwd: "/Users/me/app"),
        ]
        let url = try write(lines, name: "sess3.jsonl")
        let records = UsageAnalytics.scanFile(url, folderName: "-Users-me-app")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].tokens, 7)
    }

    func testScanEmitsRecentEventsAndDropsOldOnes() throws {
        let now = Date()
        // A recent line (2h ago) and an old one (10 days ago) via absolute timestamps.
        let recent = isoLine(at: now.addingTimeInterval(-2 * 3600), input: 30, output: 20, cwd: "/Users/me/app")
        let old = isoLine(at: now.addingTimeInterval(-10 * 24 * 3600), input: 5, output: 5, cwd: "/Users/me/app")
        let url = try write([old, recent], name: "sess-events.jsonl")

        let result = UsageAnalytics.scan(url, folderName: "-Users-me-app", now: now)
        // Records keep the full history; events keep only the recent line.
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.tokens }, 60)
        XCTAssertEqual(result.events.count, 1, "only the event within the recent window is kept")
        XCTAssertEqual(result.events.first?.tokens, 50)
        XCTAssertEqual(result.events.first?.agent, .claude)
    }

    // MARK: - Helpers

    private func isoLine(at date: Date, input: Int, output: Int, cwd: String) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let obj: [String: Any] = [
            "type": "assistant",
            "timestamp": fmt.string(from: date),
            "cwd": cwd,
            "message": ["usage": ["input_tokens": input, "output_tokens": output]],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    private func usageLine(day: String, input: Int, output: Int, cacheCreate: Int,
                           cacheRead: Int, cwd: String) -> String {
        let usage: [String: Any] = [
            "input_tokens": input, "output_tokens": output,
            "cache_creation_input_tokens": cacheCreate, "cache_read_input_tokens": cacheRead,
        ]
        let obj: [String: Any] = [
            "type": "assistant",
            "timestamp": "\(day)T12:00:00.000Z",
            "cwd": cwd,
            "message": ["usage": usage],
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ lines: [String], name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
