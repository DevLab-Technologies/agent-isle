import SwiftUI

/// Inline permission request: shows the tool, a compact diff preview, and Deny / Allow.
struct PermissionCard: View {
    let session: AgentSession
    let request: PermissionRequest
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(SessionStatus.waiting.color)
                Text("Permission Request")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(request.toolName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SessionStatus.waiting.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(SessionStatus.waiting.color.opacity(0.15)))
            }

            if let path = request.filePath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            if let command = request.command {
                Text("$ \(command)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SessionStatus.done.color.opacity(0.85))
                    .lineLimit(2)
            }

            if !request.previewLines.isEmpty {
                diffPreview
            }

            HStack(spacing: 6) {
                decisionButton("Deny", style: .deny,
                               shortcut: shortcut(.deny)) {
                    store.resolvePermission(sessionID: session.id, decision: .deny)
                }
                decisionButton("Allow Once", style: .neutral,
                               shortcut: shortcut(.allowOnce)) {
                    store.resolvePermission(sessionID: session.id, decision: .allowOnce)
                }
                decisionButton("Always Allow", style: .accent,
                               shortcut: shortcut(.always)) {
                    store.resolvePermission(sessionID: session.id, decision: .always)
                }
                decisionButton("Bypass", style: .danger,
                               shortcut: shortcut(.bypass)) {
                    store.resolvePermission(sessionID: session.id, decision: .bypass)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SessionStatus.waiting.color.opacity(0.06))
        )
    }

    // MARK: - Keyboard shortcuts

    /// Only the focus session's card wires the shortcuts, so two waiting sessions can't
    /// register the same chord (which SwiftUI would resolve ambiguously). ⌘Y / ⌘N and the
    /// modified ⌘Y variants map onto the existing decisions without touching the model.
    private var shortcutsEnabled: Bool { store.focusSession?.id == session.id }

    private func shortcut(_ decision: PermissionDecision) -> KeyboardShortcut? {
        guard shortcutsEnabled else { return nil }
        switch decision {
        case .deny:      return KeyboardShortcut("n", modifiers: .command)
        case .allowOnce: return KeyboardShortcut("y", modifiers: .command)
        case .always:    return KeyboardShortcut("y", modifiers: [.command, .option])
        case .bypass:    return KeyboardShortcut("y", modifiers: [.command, .shift])
        }
    }

    private var diffPreview: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(request.previewLines) { line in
                HStack(spacing: 6) {
                    Text(line.lineNumber.map { "\($0)" } ?? "")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 20, alignment: .trailing)
                    Text(prefix(line.kind))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                    Text(line.text)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                Text("+\(request.diffAdded)").foregroundStyle(Palette.allow)
                Text("-\(request.diffRemoved)").foregroundStyle(Palette.deny)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.top, 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Palette.allow
        case .removed: return Palette.deny
        case .context: return .white.opacity(0.55)
        }
    }

    /// Visual treatments for the four decision buttons.
    private enum DecisionStyle {
        case deny       // outline, red text
        case neutral    // white fill (the safe, common "allow once")
        case accent     // blue fill ("always allow")
        case danger     // red fill ("bypass" — the far-reaching choice)

        var fill: Color {
            switch self {
            case .deny:    return Palette.deny.opacity(0.12)
            case .neutral: return .white.opacity(0.92)
            case .accent:  return SessionStatus.working.color
            case .danger:  return Palette.deny
            }
        }
        var foreground: Color {
            switch self {
            case .deny:            return Palette.deny
            case .neutral:         return .black       // dark text on the white fill
            case .accent, .danger: return .white
            }
        }
        var stroke: Color {
            self == .deny ? Palette.deny.opacity(0.4) : .clear
        }
    }

    private func decisionButton(_ title: String, style: DecisionStyle,
                                shortcut: KeyboardShortcut? = nil,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(style.fill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(style.stroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
    }
}

/// Inline question card for Claude's AskUserQuestion. Renders every question part in one
/// card and sends all answers back together. A lone single-select part answers on tap;
/// anything else (multi-select or multiple parts) collects choices behind a Submit button.
/// Each part can also offer a free-text "Other" field.
struct QuestionCard: View {
    let session: AgentSession
    let question: AgentQuestion
    @EnvironmentObject var store: SessionStore

    // Keyed by part id, so answers stay independent across parts.
    @State private var selected: [Int: Set<Int>] = [:]
    @State private var otherText: [Int: String] = [:]
    @FocusState private var focusedOther: Int?

    private var accent: Color { SessionStatus.asking.color }

    /// A single single-select part is answered instantly on tap (no Submit needed).
    private var isSimpleSingle: Bool {
        question.parts.count == 1 && !question.parts[0].multiSelect
    }

    /// Only the focus session's card wires ⌘-number selection, so two asking sessions
    /// don't register the same chord (which SwiftUI would resolve ambiguously). We also
    /// only show the number badges when the shortcuts are actually live.
    private var shortcutsEnabled: Bool { store.focusSession?.id == session.id }

    /// Running 0-based option offset for a part, so options are numbered ⌘1…⌘9 in order
    /// across every part of the ask.
    private func optionOffset(before part: QuestionPart) -> Int {
        var n = 0
        for p in question.parts {
            if p.id == part.id { break }
            n += p.options.count
        }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                Text(question.parts.count == 1 ? question.parts[0].prompt : "Questions")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if question.parts.count > 1 {
                    Spacer(minLength: 4)
                    Text("\(question.parts.count)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.15)))
                }
            }
            ForEach(question.parts) { part in
                partSection(part)
            }
            if !isSimpleSingle {
                submitButton
                // Return submits via the button below; this hidden control adds ⌘Return
                // as an equivalent, matching the multi-select instructions.
                if shortcutsEnabled {
                    Button("", action: submit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(composedAnswer() == nil)
                        .opacity(0).frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            if question.source == .transcript {
                // No parked hook to reply to — the answer is typed into the host app.
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 8))
                    Text("Answer is typed into \(session.terminal)")
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

    @ViewBuilder
    private func partSection(_ part: QuestionPart) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // For a single part the prompt is already in the header row above.
            if question.parts.count > 1 {
                if !part.header.isEmpty {
                    Text(part.header.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                }
                Text(part.prompt)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
            }
            let base = optionOffset(before: part)
            ForEach(Array(part.options.enumerated()), id: \.offset) { idx, option in
                optionRow(part: part, idx: idx, option: option, number: base + idx + 1)
            }
            if part.allowsOther {
                otherRow(part)
            }
        }
    }

    private func optionRow(part: QuestionPart, idx: Int, option: String, number: Int) -> some View {
        let isSelected = selected[part.id]?.contains(idx) == true
        let showBadge = shortcutsEnabled && number <= 9
        return Button {
            selectOption(part: part, idx: idx, option: option)
        } label: {
            HStack(spacing: 8) {
                selectionIcon(part: part, isSelected: isSelected)
                Text(option)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                if showBadge {
                    Text("⌘\(number)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.75))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isSelected ? 0.10 : 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(isSelected ? 0.5 : 0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(showBadge
            ? KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            : nil)
    }

    @ViewBuilder
    private func selectionIcon(part: QuestionPart, isSelected: Bool) -> some View {
        // Checkbox for multi-select, radio for single-select. A lone single-select part
        // answers on tap so it never shows as selected, but the radio still reads as
        // "pick one". (Earlier ⌘-number badges were dropped — no shortcut was wired.)
        let name: String = part.multiSelect
            ? (isSelected ? "checkmark.square.fill" : "square")
            : (isSelected ? "largecircle.fill.circle" : "circle")
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? accent : .white.opacity(0.35))
    }

    private func otherRow(_ part: QuestionPart) -> some View {
        let isFocused = focusedOther == part.id
        return HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 10))
                .foregroundStyle(accent.opacity(0.8))
            TextField("Other…", text: binding(for: part.id))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .focused($focusedOther, equals: part.id)
                .onSubmit(submit)
            // A lone single-select part has no Submit button, so the field sends itself.
            if isSimpleSingle && !trimmedOther(part.id).isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(isFocused ? 0.5 : 0.25), lineWidth: 0.5)
        )
    }

    private var submitButton: some View {
        let enabled = composedAnswer() != nil
        return Button(action: submit) {
            Text(shortcutsEnabled ? "Submit  ⌘⏎" : "Submit")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(enabled ? .black : .white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(enabled ? accent : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Plain Return also submits when focus isn't in the "Other" text field (which
        // handles its own onSubmit). ⌘Return is wired alongside in the parent stack.
        .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(.return, modifiers: []) : nil)
    }

    // MARK: - State helpers

    private func binding(for partID: Int) -> Binding<String> {
        Binding(get: { otherText[partID] ?? "" },
                set: { otherText[partID] = $0 })
    }

    private func trimmedOther(_ partID: Int) -> String {
        (otherText[partID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectOption(part: QuestionPart, idx: Int, option: String) {
        if isSimpleSingle {
            sendAnswer(line(for: part, values: [option]))
            return
        }
        var set = selected[part.id] ?? []
        if part.multiSelect {
            if set.contains(idx) { set.remove(idx) } else { set.insert(idx) }
        } else {
            set = set.contains(idx) ? [] : [idx]   // radio: re-tap clears
        }
        selected[part.id] = set
    }

    /// The combined answer, or nil if any part is still unanswered. One line per part,
    /// prefixed with the part's header so Claude can map each answer to its question.
    private func composedAnswer() -> String? {
        var lines: [String] = []
        for part in question.parts {
            var values = part.options.enumerated()
                .filter { selected[part.id]?.contains($0.offset) == true }
                .map(\.element)
            let other = trimmedOther(part.id)
            if !other.isEmpty { values.append(other) }
            guard !values.isEmpty else { return nil }
            lines.append(line(for: part, values: values))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func line(for part: QuestionPart, values: [String]) -> String {
        let joined = values.joined(separator: ", ")
        return part.header.isEmpty ? joined : "\(part.header): \(joined)"
    }

    private func submit() {
        guard let composed = composedAnswer() else { return }
        sendAnswer(composed)
    }

    private func sendAnswer(_ text: String) {
        store.answerQuestion(sessionID: session.id, answer: text)
    }
}
