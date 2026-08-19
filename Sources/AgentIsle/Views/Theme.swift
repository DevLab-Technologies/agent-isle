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
        /// Inset between the notch surface's outer edge and its content. Larger than `md`
        /// because the pill's corners curve in: content set flush would ride the curve.
        static let edge: CGFloat = 20
    }

    // MARK: Corner radius
    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 9
        static let pill: CGFloat = 7
        /// Concave flare where the notch surface meets the top of the screen, so the
        /// black appears to grow out of the display edge instead of being pasted on it.
        static let notchFlare: CGFloat = 10
        /// All four corners of the panel when it floats free of the screen edge (the
        /// menu-bar popover), where a notch-continuous silhouette would be nonsense.
        static let panel: CGFloat = 16
        /// Bottom corners of the collapsed pill — tuned against the physical notch's own
        /// curvature rather than a full semicircle, which read as a separate card.
        static let notchBottom: CGFloat = 15
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

        /// Edge light for the black notch surface. Pure black on a dark desktop has no
        /// silhouette at all, so the rim carries the shape: invisible at the screen edge
        /// (where the panel merges with the bezel) and brightest along the bottom, the
        /// way macOS's own HUD surfaces are lit.
        static let rim = LinearGradient(colors: [Color.white.opacity(0.02),
                                                 Color.white.opacity(0.09),
                                                 Color.white.opacity(0.22)],
                                        startPoint: .top, endPoint: .bottom)
    }

    // MARK: Motion — live indicators should breathe, not blink.
    enum Motion {
        /// Slow scale/glow breathing for status indicators, paced like macOS live activities.
        static let breathe = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
        /// Outward halo of the "working" pulse — long enough to read as one calm ripple.
        static let halo = Animation.easeOut(duration: 1.9).repeatForever(autoreverses: false)
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
        /// The collapsed pill's session title — the one line that is always on screen.
        static func pillTitle(_ size: CGFloat = 11.5) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
        /// Prose — activity lines, chat bodies, explanatory copy. The mono face is the
        /// brand voice for identifiers and numbers; running text set in it is what makes a
        /// panel read as a debug log, so sentences get the system face instead.
        static func prose(_ size: CGFloat = 11, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight)
        }
        /// Numerals in badges and counts, where the mono face earns its keep.
        static func numeral(_ size: CGFloat = 10.5, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
