import SwiftUI

/// Top-level content of the notch panel. Draws a transparent full-width canvas and
/// centers the island under the notch, switching between collapsed and expanded states.
struct IslandRootView: View {
    let geometry: NotchGeometry
    @EnvironmentObject var store: SessionStore
    @State private var hovering = false

    private var expanded: Bool { store.isExpanded || hovering }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: expanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.orderedSessions.map(\.id))
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
        .onHover { inside in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                hovering = inside
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                store.isExpanded.toggle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
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
