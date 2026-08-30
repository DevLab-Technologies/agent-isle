import SwiftUI

/// Inline plan-review card for an agent's presented plan (e.g. Claude Code's `ExitPlanMode`).
/// Renders the plan body as Markdown and lets the user Approve it or type feedback for a
/// revision, both delivered back through the same reply path as `QuestionCard` (parked hook
/// for a hook-pushed plan, or typed into the host app for a transcript-detected one).
struct PlanReviewCard: View {
    let session: AgentSession
    let plan: AgentPlan
    @EnvironmentObject var store: SessionStore

    @State private var feedback: String = ""
    @FocusState private var feedbackFocused: Bool

    private var accent: Color { SessionStatus.planning.color }

    /// Only the focus session's card wires the keyboard chords, so two plan cards can't
    /// register the same shortcut (which SwiftUI would resolve ambiguously). Mirrors the
    /// approach in PermissionCard / QuestionCard.
    private var shortcutsEnabled: Bool { store.focusSession?.id == session.id }

    private var hasFeedback: Bool {
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            planBody
            feedbackField
            actions
            if plan.source == .transcript {
                // No parked hook to reply to — the answer is typed into the host app.
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 8))
                    Text("Reply is typed into \(session.terminal)")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(0.06))
        )
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .font(.system(size: 10))
                .foregroundStyle(accent)
            Text("Plan Review")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(session.agent.displayName)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.15)))
        }
    }

    private var planBody: some View {
        ScrollView {
            MarkdownText(plan.markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 260)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private var feedbackField: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 10))
                .foregroundStyle(accent.opacity(0.8))
            TextField("Request changes (optional)…", text: $feedback)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .focused($feedbackFocused)
                .onSubmit { if hasFeedback { sendFeedback() } }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(feedbackFocused ? 0.5 : 0.25), lineWidth: 0.5)
        )
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton(hasFeedback && shortcutsEnabled ? "Send Feedback  ⌘⏎" : "Send Feedback",
                         style: .neutral, enabled: hasFeedback,
                         shortcut: (shortcutsEnabled && hasFeedback)
                            ? KeyboardShortcut(.return, modifiers: .command) : nil,
                         action: sendFeedback)
            actionButton(shortcutsEnabled ? "Approve  ⌘Y" : "Approve",
                         style: .accent, enabled: true,
                         shortcut: shortcutsEnabled
                            ? KeyboardShortcut("y", modifiers: .command) : nil,
                         action: approve)
        }
    }

    // MARK: - Actions

    private func approve() {
        store.approvePlan(sessionID: session.id)
    }

    private func sendFeedback() {
        guard hasFeedback else { return }
        store.sendPlanFeedback(sessionID: session.id, feedback: feedback)
    }

    // MARK: - Button styling (mirrors PermissionCard's decision buttons)

    private enum ActionStyle {
        case neutral    // outline — the secondary "send feedback"
        case accent     // filled — the primary "approve"
    }

    private func actionButton(_ title: String, style: ActionStyle, enabled: Bool,
                              shortcut: KeyboardShortcut?,
                              action: @escaping () -> Void) -> some View {
        let fill: Color = style == .accent
            ? (enabled ? accent : accent.opacity(0.4))
            : Color.white.opacity(enabled ? 0.06 : 0.03)
        let fg: Color = style == .accent
            ? .black
            : (enabled ? .white.opacity(0.9) : .white.opacity(0.35))
        return Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(fg)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style == .neutral ? accent.opacity(enabled ? 0.35 : 0.15) : .clear,
                                lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(shortcut)
    }
}

// MARK: - Markdown rendering

/// A lightweight block-level Markdown renderer for plan bodies. SwiftUI's `Text` handles
/// inline Markdown (bold, italic, `code`, links) via `AttributedString`, but not block
/// elements — so this splits the source into blocks (headings, ordered/bulleted lists,
/// fenced code, blockquotes, paragraphs) and lays each out, delegating inline styling to
/// `AttributedString`. No third-party dependencies.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) { self.markdown = markdown }

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: headingSize(level), weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, level <= 2 ? 2 : 0)

        case .paragraph(let text):
            inline(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text):
            listRow(marker: "•", text: text)

        case .ordered(let number, let text):
            listRow(marker: "\(number).", text: text)

        case .quote(let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 2)
                inline(text)
                    .font(.system(size: 11, design: .monospaced).italic())
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SessionStatus.done.color.opacity(0.9))
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5)))
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(minWidth: 14, alignment: .trailing)
            inline(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 14
        case 2: return 12.5
        default: return 11.5
        }
    }

    /// Render inline Markdown (bold/italic/`code`/links). Falls back to the raw string if
    /// the source can't be parsed as an attributed string.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// One block element parsed from a Markdown source.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case ordered(number: Int, text: String)
    case quote(String)
    case code(String)

    /// Split a Markdown string into ordered block elements. Deliberately small: it covers
    /// what agent plans use (headings, lists, fenced code, blockquotes, paragraphs) and
    /// treats anything else as paragraph text.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks — collect verbatim until the closing fence.
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            // Heading: one to six leading '#'.
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // Bulleted list: -, * or + followed by a space.
            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }

            // Ordered list: "<n>." followed by a space.
            if let ordered = parseOrdered(trimmed) {
                flushParagraph()
                blocks.append(ordered)
                continue
            }

            paragraph.append(trimmed)
        }
        // Close any unterminated code fence, then flush the trailing paragraph.
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseOrdered(_ line: String) -> MarkdownBlock? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return .ordered(number: Int(digits) ?? 0, text: text)
    }
}
