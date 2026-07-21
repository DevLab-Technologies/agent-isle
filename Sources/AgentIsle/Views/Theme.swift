import SwiftUI

/// Central design tokens for the island UI, so every view pulls spacing, radius, and
/// text treatment from one place. The app keeps its terminal identity (monospaced type),
/// but leans on generous spacing and a small, consistent scale for a calmer, more
/// readable panel — closer to a native surface than a dense debug readout.
enum Theme {
    // MARK: Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
    }

    // MARK: Corner radius
    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 9
        static let pill: CGFloat = 7
    }

    // MARK: Foreground opacities (on the black panel)
    enum Ink {
        static let primary = Color.white.opacity(0.95)
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.42)
        static let faint = Color.white.opacity(0.28)
    }

    // MARK: Surfaces
    enum Fill {
        static let card = Color.white.opacity(0.045)
        static let cardHover = Color.white.opacity(0.075)
        static let inset = Color.black.opacity(0.35)
        static let hairline = Color.white.opacity(0.07)
    }

    // MARK: Type — monospaced brand face at a small, deliberate scale.
    enum Font {
        static func title(_ size: CGFloat = 13) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .monospaced)
        }
        static func body(_ size: CGFloat = 11.5) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }
        static func label(_ size: CGFloat = 10, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
