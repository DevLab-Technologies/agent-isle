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

            HStack(spacing: 8) {
                actionButton("Deny", shortcut: "⌘N", tint: Palette.deny) {
                    store.resolvePermission(sessionID: session.id, allow: false)
                }
                actionButton("Allow", shortcut: "⌘Y", tint: Palette.allow, filled: true) {
                    store.resolvePermission(sessionID: session.id, allow: true)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SessionStatus.waiting.color.opacity(0.06))
        )
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

    private func actionButton(_ title: String, shortcut: String, tint: Color,
                              filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(shortcut)
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.6)
            }
            .foregroundStyle(filled ? .black : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(filled ? tint : tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(filled ? 0 : 0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
            ForEach(Array(part.options.enumerated()), id: \.offset) { idx, option in
                optionRow(part: part, idx: idx, option: option)
            }
            if part.allowsOther {
                otherRow(part)
            }
        }
    }

    private func optionRow(part: QuestionPart, idx: Int, option: String) -> some View {
        let isSelected = selected[part.id]?.contains(idx) == true
        return Button {
            selectOption(part: part, idx: idx, option: option)
        } label: {
            HStack(spacing: 8) {
                selectionIcon(part: part, isSelected: isSelected)
                Text(option)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isSelected ? 0.10 : 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(isSelected ? 0.5 : 0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
            Text("Submit")
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
