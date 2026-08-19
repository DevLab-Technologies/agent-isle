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
                    .font(Theme.Font.label(9.5, weight: .regular))
                    .foregroundStyle(Theme.Ink.tertiary)
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
                // A plain VStack (not LazyVStack): the message list is capped at 80 rows,
                // so laziness buys nothing — and a LazyVStack has no stable ideal height,
                // which sends the layout engine into an unbounded prefetch/size loop once
                // ExpandedIsland's `.fixedSize()` measures the scroll view with an ideal
                // (unbounded) height proposal. A VStack reports a definite ideal height, so
                // `.frame(maxHeight:)` bounds the scroll view exactly as it does for the
                // session list.
                VStack(alignment: .leading, spacing: 10) {
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
            .scrollIndicators(.never)
            // The transcript is clipped top and bottom; fading those edges reads as
            // "more above/below" instead of a bubble sliced by the panel border. Fixed
            // heights matching the list padding, so a short conversation isn't dimmed.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0), .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Theme.Space.md)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Theme.Space.md)
                }
            )
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
            .font(Theme.Font.prose(11.5))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let err = store.sendError(for: session.id) {
                SendErrorNotice(message: err.message,
                                showsAccessibilityButton: err.needsAccessibility)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField("Message \(session.agent.displayName)…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.prose(12))
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

    /// A turn that is nothing but machine notices belongs to neither side of the
    /// conversation, so it runs centered across the full width instead of as a bubble.
    private var isSystemNotice: Bool {
        !message.blocks.isEmpty && message.blocks.allSatisfy {
            if case .notice = $0 { return true } else { return false }
        }
    }

    var body: some View {
        HStack {
            if message.role == .user, !isSystemNotice { Spacer(minLength: 32) }
            VStack(alignment: isSystemNotice ? .center : (message.role == .user ? .trailing : .leading),
                   spacing: 5) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: isSystemNotice ? .infinity : nil)
            if message.role == .assistant, !isSystemNotice { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(Theme.Font.prose(11.5))
                .foregroundStyle(.white.opacity(message.role == .user ? 0.95 : 0.85))
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 7)
                // One surface per bubble: the fill alone separates the roles, so the ring
                // that used to outline every bubble is gone.
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(message.role == .user ? tint.opacity(0.16) : Theme.Fill.card)
                )
        case .notice(let text):
            HStack(spacing: 5) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 8))
                Text(text)
                    .font(Theme.Font.prose(10))
                    .lineLimit(2)
            }
            .foregroundStyle(Theme.Ink.faint)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 3)
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
            // Tool output stays monospaced — it is literal terminal text — but hangs off a
            // rule instead of sitting in a card, so it reads as a margin note next to the
            // tool call rather than as another message.
            Text(text)
                .font(Theme.Font.body(9.5))
                .foregroundStyle(Theme.Ink.faint)
                .lineLimit(2)
                .padding(.leading, Theme.Space.md)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.Fill.hairline).frame(width: 2)
                }
                .padding(.vertical, 2)
        }
    }
}
