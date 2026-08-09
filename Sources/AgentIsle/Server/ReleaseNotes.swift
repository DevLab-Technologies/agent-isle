import AppKit
import Foundation

/// Renders a GitHub release body (Markdown) into styled text for the update prompt.
///
/// Release notes arrive as raw Markdown — headings, bullets, `**bold**`, links — which reads
/// badly when dropped into an alert verbatim. We parse it with Foundation's Markdown support
/// and map the block/inline intents onto AppKit attributes: headings get a larger bold font,
/// list items get a bullet and a hanging indent, code stays monospaced, links stay clickable.
///
/// Unsupported or malformed Markdown degrades to plain text rather than failing: the parser is
/// asked for a partial parse, and if even that fails we show the source as-is.
enum ReleaseNotes {

    private static let bodySize = NSFont.systemFontSize
    private static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }

    /// Styled release notes, or an empty string when there's nothing to show.
    static func attributed(_ markdown: String) -> NSAttributedString {
        let source = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return NSAttributedString() }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source,
                                      attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        }

        let out = NSMutableAttributedString()
        for block in blocks(in: parsed) {
            let rendered = render(block)
            guard rendered.length > 0 else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(rendered)
        }
        return out
    }

    /// The rendered notes as plain text — same block structure, no styling. Used where an
    /// attributed string can't go (e.g. a notification body).
    static func plainText(_ markdown: String) -> String {
        attributed(markdown).string
    }

    // MARK: - Blocks

    /// A run of inline text that shares one block-level intent (a paragraph, a list item, …).
    private struct Block {
        let intent: PresentationIntent?
        let text: NSMutableAttributedString
    }

    /// Group the parsed runs into blocks. Foundation gives every block a distinct identity, so
    /// consecutive runs belong together exactly when their presentation intents are equal.
    private static func blocks(in parsed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        for run in parsed.runs {
            let piece = inline(String(parsed[run.range].characters), run: run)
            if let last = blocks.last, last.intent == run.presentationIntent {
                last.text.append(piece)
            } else {
                blocks.append(Block(intent: run.presentationIntent, text: piece))
            }
        }
        return blocks
    }

    private static func render(_ block: Block) -> NSAttributedString {
        let kinds = block.intent?.components.map(\.kind) ?? []
        var headerLevel = 0
        var listDepth = 0
        var ordinal: Int?
        var isOrdered = false
        var isCode = false
        var isQuote = false

        for kind in kinds {
            switch kind {
            case .header(let level):        headerLevel = level
            case .listItem(let n):          ordinal = n
            case .unorderedList:            listDepth += 1
            case .orderedList:              listDepth += 1; isOrdered = true
            case .codeBlock:                isCode = true
            case .blockQuote:               isQuote = true
            case .thematicBreak:            return separator()
            default:                        break
            }
        }

        let text = NSMutableAttributedString(attributedString: block.text)
        // Foundation keeps the newlines inside code blocks; everything else is a single line.
        trimTrailingNewlines(text)
        guard text.length > 0 else { return NSAttributedString() }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1
        style.paragraphSpacing = headerLevel > 0 ? 2 : 4

        if headerLevel > 0 {
            let size = headerLevel <= 1 ? bodySize + 3 : (headerLevel == 2 ? bodySize + 1 : bodySize)
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold),
                              range: NSRange(location: 0, length: text.length))
            style.paragraphSpacingBefore = 6
        }
        if isQuote {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                              range: NSRange(location: 0, length: text.length))
        }
        if isCode {
            text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular),
                              range: NSRange(location: 0, length: text.length))
        }

        if listDepth > 0 || isQuote {
            let indent = CGFloat(max(listDepth, 1)) * 16
            style.firstLineHeadIndent = indent - 16
            style.headIndent = indent
            style.paragraphSpacing = 1
            let marker = isQuote ? "❯ " : (isOrdered ? "\(ordinal ?? 1). " : bullet(depth: listDepth))
            text.insert(NSAttributedString(string: marker,
                                           attributes: [.font: bodyFont,
                                                        .foregroundColor: NSColor.secondaryLabelColor]),
                        at: 0)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        } else if isCode {
            style.firstLineHeadIndent = 12
            style.headIndent = 12
        }

        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Nesting-aware bullet glyphs, mirroring how Markdown renderers vary them by depth.
    private static func bullet(depth: Int) -> String {
        switch depth {
        case 1:  return "•  "
        case 2:  return "◦  "
        default: return "▪  "
        }
    }

    private static func separator() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.paragraphSpacingBefore = 4
        return NSAttributedString(string: "――――――",
                                  attributes: [.font: bodyFont,
                                               .foregroundColor: NSColor.tertiaryLabelColor,
                                               .paragraphStyle: style])
    }

    // MARK: - Inline

    private static func inline(_ text: String, run: AttributedString.Runs.Run) -> NSMutableAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        let intent = run.inlinePresentationIntent ?? []

        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }

        if intent.contains(.code) {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
        } else if !traits.isEmpty {
            let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(traits)
            attrs[.font] = NSFont(descriptor: descriptor, size: bodySize) ?? bodyFont
        }
        if intent.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
            attrs[.link] = link
        }
        return NSMutableAttributedString(string: text, attributes: attrs)
    }

    private static func trimTrailingNewlines(_ text: NSMutableAttributedString) {
        while let last = text.string.last, last.isNewline {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
    }
}
