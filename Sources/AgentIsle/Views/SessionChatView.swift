import SwiftUI

/// The live conversation for one session: a scrollable transcript that tails the
/// session's file in real time, plus an input bar to send a message back into it.
struct SessionChatView: View {
    let session: AgentSession
    @EnvironmentObject var store: SessionStore
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            messageList
            inputBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { store.closeChat() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)

            AgentBadge(agent: session.agent)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text("\(session.agent.displayName) · \(session.terminal)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            StatusPill(status: session.status)

            Button(action: { Jumper.jump(to: session) }) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Jump to terminal")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.openedMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.openedMessages) { message in
                            ChatMessageView(message: message, tint: session.agent.tint)
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(12)
            }
            .frame(maxHeight: 300)
            .onChange(of: store.openedMessages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private let bottomAnchor = "chat-bottom"

    @ViewBuilder private var emptyState: some View {
        if session.transcriptURL == nil || !ChatHistory.isSupported(session.agent) {
            chatNotice("Live history isn't available for this session.\nYou can still send a message below.")
        } else if store.chatLoading {
            chatNotice("Loading conversation…")
        } else {
            chatNotice("No messages yet.")
        }
    }

    private func chatNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let err = store.sendError {
                Text(err)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.deny)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField("Message \(session.agent.displayName)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.1), lineWidth: 0.5))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSend ? session.agent.tint : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .onAppear { DispatchQueue.main.async { inputFocused = true } }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        store.sendMessage(draft, to: session)
        draft = ""
        inputFocused = true
    }
}

/// A single message rendered as stacked blocks (text, thinking, tool calls, results).
struct ChatMessageView: View {
    let message: ChatMessage
    let tint: Color

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(message.role == .user ? 0.95 : 0.85))
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(message.role == .user ? tint.opacity(0.18) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(message.role == .user ? tint.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 0.5)
                )
        case .thinking(let text):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .italic()
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(4)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        case .toolUse(let name, let detail):
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(tint.opacity(0.8))
                Text(detail.map { "\(name): \($0)" } ?? name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.08)))
        case .toolResult(let text):
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(3)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
        }
    }
}
