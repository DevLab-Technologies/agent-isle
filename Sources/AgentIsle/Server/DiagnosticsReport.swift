import Foundation
import OSLog

/// Assembles a plain-text diagnostics report for support: app + OS metadata, the
/// Integration Doctor results, event-server reachability, and recent process log lines.
///
/// Metadata only — it never reads session transcripts, prompts, or chat content. The log
/// tail comes from this process's own unified-logging entries (i.e. the app's own `NSLog`
/// / `os_log` status and error lines), not the whole system.
enum DiagnosticsReport {

    /// Gather everything and render the report. Runs the (potentially slow) log query and
    /// doctor checks synchronously, so call it off the main thread if responsiveness matters.
    static func build() -> String {
        render(appVersion: ProblemReport.appVersion,
               osVersion: ProblemReport.osVersion,
               architecture: ProblemReport.architecture,
               memoryFootprintMB: MemoryWatchdog.residentBytes().map { $0 / (1024 * 1024) },
               serverPort: EventServer.port,
               serverReachable: IntegrationDoctor.serverReachable(),
               reports: IntegrationDoctor.run(),
               logLines: recentLogLines(),
               generatedAt: Date())
    }

    /// Pure renderer: given already-gathered inputs, produce the report text. Kept free of
    /// I/O so it can be unit-tested deterministically.
    static func render(appVersion: String,
                       osVersion: String,
                       architecture: String,
                       memoryFootprintMB: UInt64?,
                       serverPort: UInt16,
                       serverReachable: Bool,
                       reports: [IntegrationDoctor.Report],
                       logLines: [String],
                       generatedAt: Date) -> String {
        let df = ISO8601DateFormatter()
        var out = ""

        out += "Agent Isle Diagnostics\n"
        out += "======================\n"
        out += "Generated: \(df.string(from: generatedAt))\n\n"

        out += "Environment\n"
        out += "-----------\n"
        out += "Agent Isle version: \(appVersion)\n"
        out += "macOS version:      \(osVersion)\n"
        out += "Mac:                \(architecture)\n"
        out += "Memory footprint:   \(memoryFootprintMB.map { "\($0) MB" } ?? "unavailable")\n\n"

        out += "Event server\n"
        out += "------------\n"
        out += "Listening on localhost:\(serverPort): \(serverReachable ? "reachable" : "NOT reachable")\n\n"

        out += "Integrations\n"
        out += "------------\n"
        if reports.isEmpty {
            out += "No supported CLIs detected.\n"
        } else {
            for report in reports {
                out += "\(report.displayName) [\(label(report.overall))]\n"
                for check in report.checks {
                    out += "  - [\(label(check.status))] \(check.title): \(check.detail)\n"
                }
            }
        }
        out += "\n"

        out += "Recent log (this process)\n"
        out += "-------------------------\n"
        if logLines.isEmpty {
            out += "No recent log entries available.\n"
        } else {
            out += logLines.joined(separator: "\n")
            out += "\n"
        }

        return out
    }

    /// A dated default filename for the save panel, e.g. "AgentIsle-Diagnostics-2026-07-22.txt".
    static func defaultFileName(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "AgentIsle-Diagnostics-\(df.string(from: date)).txt"
    }

    private static func label(_ status: IntegrationDoctor.Status) -> String {
        switch status {
        case .ok:   return "OK"
        case .warn: return "WARN"
        case .fail: return "FAIL"
        case .info: return "INFO"
        }
    }

    /// Recent log entries emitted by this process, newest last. Metadata-level status/error
    /// lines only; capped so the report stays small. Best-effort — returns [] if the log
    /// store is unavailable.
    private static func recentLogLines(limit: Int = 200, lookback: TimeInterval = 3600) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let start = store.position(date: Date().addingTimeInterval(-lookback))
        guard let entries = try? store.getEntries(at: start) else { return [] }

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let lines = entries.compactMap { entry -> String? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return "\(df.string(from: log.date)) \(log.composedMessage)"
        }
        return Array(lines.suffix(limit))
    }
}
