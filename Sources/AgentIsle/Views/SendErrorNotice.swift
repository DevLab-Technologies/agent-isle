import SwiftUI

/// Why a send failed, plus the one deliberate way into Accessibility settings.
///
/// Shown under the chat input *and* on the session's card in the list: a question or plan is
/// often answered from the list, where there is no input bar, and the failure must stay put —
/// the transcript poller rewrites `lastMessage` every couple of seconds, so a notice written
/// there would vanish before the user looked back.
struct SendErrorNotice: View {
    let message: String
    let showsAccessibilityButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(message)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.deny)
                .fixedSize(horizontal: false, vertical: true)
            // Agent Isle never opens System Settings by itself (that nagging is what this
            // replaces) — the trip there is one deliberate tap.
            if showsAccessibilityButton {
                Button("Open Accessibility settings") {
                    AccessibilityPermission.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
