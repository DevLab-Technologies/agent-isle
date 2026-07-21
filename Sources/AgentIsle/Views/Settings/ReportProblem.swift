import SwiftUI

/// Builds a pre-filled GitHub "new issue" URL from a short report plus
/// auto-collected environment diagnostics. Nothing is submitted from the app:
/// the URL opens the browser with the issue form populated so the user can
/// review and post it themselves.
enum ProblemReport {
    static let repo = "DevLab-Technologies/agent-isle"

    /// App version, e.g. "0.4.2", falling back to "dev" for unbundled builds.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Human-readable macOS version, e.g. "14.5.0".
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// CPU family the app is running as.
    static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "Unknown"
        #endif
    }

    /// The environment block appended to every report, mirroring the repo's
    /// bug_report template so triaged issues stay consistent.
    static var environmentBlock: String {
        """
        **Environment**
        - macOS version: \(osVersion)
        - Mac: \(architecture)
        - Agent Isle version: \(appVersion)
        """
    }

    /// Upper bound on the user-supplied description. GitHub returns HTTP 414
    /// once the whole new-issue URL grows past ~8 KB, so we cap the free-text
    /// portion well under that and let the user paste the rest on GitHub.
    static let maxDetailsLength = 6000

    /// `URLComponents.queryItems` leaves `&`, `+`, and `=` unescaped in values
    /// (they're legal query sub-delimiters), which corrupts titles/bodies that
    /// contain them. Encode explicitly against a stricter set instead.
    private static let queryValueAllowed =
        CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }

    /// Assembles the GitHub new-issue URL with the title/body query params.
    static func issueURL(title: String, details: String) -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = String(
            details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxDetailsLength))

        let body = """
        **What happened**
        \(trimmedDetails.isEmpty ? "_Describe the problem._" : trimmedDetails)

        \(environmentBlock)
        """

        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")
        components?.percentEncodedQueryItems = [
            URLQueryItem(name: "labels", value: encode("bug")),
            URLQueryItem(name: "title", value: encode("[bug] \(trimmedTitle)")),
            URLQueryItem(name: "body", value: encode(body)),
        ]
        return components?.url
    }
}

/// A compact compose sheet for reporting a problem. Collects a title and
/// description, shows the diagnostics that will be attached, and hands the
/// user off to GitHub to submit.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconTile(symbol: "exclamationmark.bubble.fill", tint: .orange, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a Problem").font(.system(size: 17, weight: .bold))
                    Text("Opens a pre-filled issue on GitHub for you to review and submit.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SUMMARY").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                TextField("Short summary of the problem", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("WHAT HAPPENED").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if details.count > ProblemReport.maxDetailsLength - 500 {
                        Text("\(details.count)/\(ProblemReport.maxDetailsLength)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(details.count > ProblemReport.maxDetailsLength ? .red : .secondary)
                    }
                }
                TextEditor(text: $details)
                    .font(.system(size: 13))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    .overlay(alignment: .topLeading) {
                        if details.isEmpty {
                            Text("Describe the problem and steps to reproduce it.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .padding(.horizontal, 11).padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
            }

            SettingsGroup(title: "Attached diagnostics") {
                DiagnosticRow(label: "macOS", value: ProblemReport.osVersion)
                DiagnosticRow(label: "Mac", value: ProblemReport.architecture)
                DiagnosticRow(label: "Agent Isle", value: ProblemReport.appVersion, showsDivider: false)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue on GitHub") {
                    if let url = ProblemReport.issueURL(title: title, details: details) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String
    var showsDivider: Bool = true
    var body: some View {
        SettingsRow(title: label, showsDivider: showsDivider) {
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
