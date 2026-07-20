import SwiftUI

/// The app's logo — a neon terminal prompt (`>` chevron + block cursor) matching the
/// app icon. Drawn with Canvas so it stays crisp at any size in the island UI.
struct AppMark: View {
    var size: CGFloat = 14

    private let cyan = Color(red: 0.39, green: 0.94, blue: 0.91)
    private let magenta = Color(red: 1.0, green: 0.37, blue: 0.64)

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)

            var chevron = Path()
            chevron.move(to: CGPoint(x: s * 0.14, y: s * 0.24))
            chevron.addLine(to: CGPoint(x: s * 0.47, y: s * 0.5))
            chevron.addLine(to: CGPoint(x: s * 0.14, y: s * 0.76))
            ctx.stroke(chevron, with: .color(cyan),
                       style: StrokeStyle(lineWidth: s * 0.13, lineCap: .round, lineJoin: .round))

            let block = Path(roundedRect: CGRect(x: s * 0.58, y: s * 0.30,
                                                 width: s * 0.20, height: s * 0.40),
                             cornerRadius: s * 0.05)
            ctx.fill(block, with: .color(magenta))
        }
        .frame(width: size, height: size)
        .shadow(color: cyan.opacity(0.5), radius: size * 0.12)
    }
}
