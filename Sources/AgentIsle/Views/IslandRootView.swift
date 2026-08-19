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
        // Only the collapsed pill emits a shift; with the expanded panel on screen no view
        // sets the key, so it falls back to the default of zero.
        .onPreferenceChange(IslandOffsetKey.self) { store.islandOffsetX = $0 }
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

/// Carries the collapsed pill's horizontal shift up to the window, so the click-through
/// rect can be placed over where the island actually renders.
struct IslandOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A notch-flush black container: it meets the top of the screen edge-to-edge, curves
/// *inward* just below it (`topRadius`), and rounds off at the bottom — the silhouette of
/// Apple's own notch surfaces, where the black appears to grow out of the display edge
/// rather than being a rounded card hung underneath it. `topRadius: 0` gives the older
/// straight-sided shape.
struct NotchShape: Shape {
    /// Radius of the concave flare at the two top corners. The body below the flare is
    /// inset by this much on each side, so content needs at least that much edge padding.
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tr = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let left = rect.minX + tr
        let right = rect.maxX - tr
        let br = max(0, min(bottomRadius, (right - left) / 2, rect.height - tr))

        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Full-width top edge, flush with the screen bezel.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Concave flare down into the right body edge.
        p.addQuadCurve(to: CGPoint(x: right, y: rect.minY + tr),
                       control: CGPoint(x: right, y: rect.minY))
        p.addLine(to: CGPoint(x: right, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: right - br, y: rect.maxY),
                       control: CGPoint(x: right, y: rect.maxY))
        p.addLine(to: CGPoint(x: left + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - br),
                       control: CGPoint(x: left, y: rect.maxY))
        p.addLine(to: CGPoint(x: left, y: rect.minY + tr))
        // ...and back out through the left flare.
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: left, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
