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

/// Inline multiple-choice question card.
struct QuestionCard: View {
    let session: AgentSession
    let question: AgentQuestion
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(SessionStatus.asking.color)
                Text(question.prompt)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            VStack(spacing: 5) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                    Button {
                        store.answerQuestion(sessionID: session.id, option: option)
                    } label: {
                        HStack {
                            Text("⌘\(idx + 1)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(SessionStatus.asking.color)
                            Text(option)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(SessionStatus.asking.color.opacity(0.25), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SessionStatus.asking.color.opacity(0.06))
        )
    }
}
