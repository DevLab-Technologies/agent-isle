import SwiftUI

/// Text that never hides its content behind an ellipsis. It renders up to
/// `collapsedLineLimit` lines, and when the string is longer it offers a Show more /
/// Show less toggle (the text itself is tappable too) plus a hover tooltip carrying the
/// whole string. Used for questions, prompts and commands — copy the user has to read in
/// full before answering, where a clipped line means guessing.
struct ExpandableText: View {
    let text: String
    let font: Font
    let color: Color
    let accent: Color
    /// Lines shown before the toggle appears. Deliberately generous: the panel scrolls,
    /// so a few extra lines cost less than a hidden question.
    var collapsedLineLimit: Int = 4

    @State private var expanded = false
    @State private var clippedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// True once the collapsed copy is measurably shorter than the full one. Expanded, the
    /// two match by definition, so `expanded` keeps the toggle on screen to collapse again.
    private var showsToggle: Bool {
        expanded || (clippedHeight > 0 && fullHeight > clippedHeight + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(expanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .measureHeight(ClippedHeightKey.self) { clippedHeight = $0 }
                // The same string, unclipped, laid out at the same width but never drawn:
                // taller than what's on screen means the visible copy is truncated.
                .background(
                    Text(text)
                        .font(font)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .measureHeight(FullHeightKey.self) { fullHeight = $0 }
                        .hidden()
                        .allowsHitTesting(false),
                    alignment: .top
                )
            if showsToggle { toggle }
        }
        .help(text)
        .contentShape(Rectangle())
        .onTapGesture { if showsToggle { expanded.toggle() } }
        // A superseding request can hand a reused view a different string (SessionRow
        // doesn't key every card on its payload), and a stale `expanded` would leave a
        // Show-less toggle on text that isn't truncated at all.
        .onChange(of: text) { _, _ in expanded = false }
    }

    private var toggle: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                Text(expanded ? "Show less" : "Show more")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(accent.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

// Two keys, one per copy: a single key would let the hidden probe's height bubble into
// the visible copy's reader and report both as the same height (never truncated).
private struct ClippedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct FullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Reports this view's laid-out height through `key`.
    func measureHeight<K: PreferenceKey>(_ key: K.Type,
                                        _ onChange: @escaping (CGFloat) -> Void) -> some View
    where K.Value == CGFloat {
        overlay(
            GeometryReader { geo in
                Color.clear.preference(key: K.self, value: geo.size.height)
            }
            .allowsHitTesting(false)
        )
        .onPreferenceChange(K.self) { onChange($0) }
    }
}
