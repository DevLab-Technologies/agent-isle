import SwiftUI

/// Top-level content of the notch panel. Draws a transparent full-width canvas and
/// centers the island under the notch, switching between collapsed and expanded states.
struct IslandRootView: View {
    let geometry: NotchGeometry
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var settings: AppSettings

    private var expanded: Bool {
        store.isExpanded || (settings.expandOnHover && store.hoverExpanded) || store.isPinned
    }

    var body: some View {
        VStack(spacing: 0) {
            island
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: IslandSizeKey.self, value: proxy.size)
                    }
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(IslandSizeKey.self) { size in
            // Report the rendered island size so the window can shrink to fit it.
            if size.width > 1, size.height > 1 { store.islandSize = size }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: expanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.visibleSessions.map(\.id))
    }

    private var island: some View {
        Group {
            if expanded {
                ExpandedIsland(notchWidth: geometry.notchWidth,
                               notchHeight: geometry.notchHeight)
            } else {
                CollapsedIsland(notchWidth: geometry.notchWidth,
                                notchHeight: geometry.notchHeight)
            }
        }
        .contentShape(Rectangle())   // whole bounds hoverable, incl. the notch gap
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                // Toggle based on what's actually on screen, not just `isExpanded`:
                // when the panel is open via hover-latch or a pinned chat, a tap should
                // force it shut rather than silently flip a flag that changes nothing.
                if expanded {
                    store.forceCollapse()
                } else {
                    store.isExpanded = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// Propagates the rendered island size up to the window so it can shrink to fit.
struct IslandSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > value.width || next.height > value.height { value = next }
    }
}

/// A notch-flush black container: square top corners (merging with the screen edge)
/// and rounded bottom corners, like the real Dynamic Island.
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, rect.width / 2)
        let br = min(bottomRadius, rect.width / 2)

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top edge with slight inner curve
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // right side down to bottom-right corner
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        // bottom edge
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - br),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        _ = tr
        return p
    }
}
