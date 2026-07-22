import SwiftUI

/// The content hosted inside the menu-bar `NSPopover`. It reuses the exact expanded
/// island panel (`ExpandedIsland`) — the same session list, live chat, approve/answer/jump
/// controls, and gear menu — but with no physical-notch gap, since a popover has none.
///
/// The popover shares the app's single `SessionStore`/`AppSettings`, so everything stays
/// in sync with the notch island when both surfaces are shown (`.both`).
struct MenuBarPanel: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ExpandedIsland(notchWidth: 0, notchHeight: 34)
            .padding(6)
            // Re-run the panel's spring layout when the session set or open chat changes,
            // matching the notch island's animation feel.
            .animation(.spring(response: 0.42, dampingFraction: 0.82),
                       value: store.orderedSessions.map(\.id))
            .animation(.spring(response: 0.42, dampingFraction: 0.82),
                       value: store.openedSessionID)
    }
}
