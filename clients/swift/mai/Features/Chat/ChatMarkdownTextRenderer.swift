import Markdown

#if os(macOS)
    import AppKit

    private typealias ChatPlatformColor = NSColor
    private typealias ChatPlatformFont = NSFont
#else
    import UIKit

    private typealias ChatPlatformColor = UIColor
    private typealias ChatPlatformFont = UIFont
#endif

extension NSAttributedString.Key {
    nonisolated static let chatQuoteBarOffsets = Self("ChatQuoteBarOffsets")
    nonisolated static let chatThematicBreakIndent =
        Self("ChatThematicBreakIndent")
}

/// Rendered Markdown text. The attributed string is immutable once built, so
/// render plans can carry it across actors.
nonisolated struct ChatMarkdownText: Equatable, @unchecked Sendable {
    let value: NSAttributedString

    init(_ value: NSAttributedString) {
        self.value = value
    }

    var string: String { value.string }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value === rhs.value || lhs.value.isEqual(to: rhs.value)
    }
}

/// The one place where chat Markdown becomes styled text. Settled, live and
/// resolved prose and table cells all render here, so rows cannot diverge.
/// Rich root blocks (code, tables) are routed elsewhere by the planner.
nonisolated enum ChatMarkdownTextRenderer {
    static func attributedString(from source: String) -> NSAttributedString {
        attributedString(
            blocks: Markdown.Document(chatSource: source).children,
            source: source
        )
    }

    /// Renders already-parsed root blocks. `source` is the text the blocks
    /// were parsed from; whole-document state such as reference links is
    /// already resolved in the blocks.
    static func attributedString(
        blocks: some Sequence<Markup>,
        source: String
    ) -> NSAttributedString {
        var builder = ChatMarkdownAttributedStringBuilder(source: source)
        for block in blocks {
            builder.append(block: block, environment: .root)
        }
        return builder.finish()
    }

    static func attributedString(
        tableCell children: some Sequence<Markup>,
        isHeader: Bool
    ) -> NSAttributedString {
        ChatMarkdownAttributedStringBuilder(source: "")
            .inlineText(children, isBold: isHeader)
    }

    /// Source with no renderable Markdown blocks, shown as written.
    static func plainAttributedString(_ text: String) -> NSAttributedString {
        ChatMarkdownAttributedStringBuilder(source: "")
            .inlineText(text, isBold: false)
    }

    /// Joins separately rendered root-block runs exactly as rendering their
    /// blocks together would.
    static func joined(
        _ runs: some Sequence<NSAttributedString>
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs where run.length > 0 {
            if output.length > 0 {
                // Restore the paragraph terminator `finish()` trimmed.
                let previous = output.attributes(
                    at: output.length - 1,
                    effectiveRange: nil
                )
                output.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: previous.filter {
                            ChatMarkdownAttributedStringBuilder
                                .paragraphTerminatorKeys.contains($0.key)
                        }
                    )
                )
                ChatMarkdownAttributedStringBuilder.appendBlockSpacer(
                    to: output,
                    height: ChatMarkdownProseStyle.blockSpacing,
                    connectingTo: run.attribute(
                        .chatQuoteBarOffsets,
                        at: 0,
                        effectiveRange: nil
                    ) as? [CGFloat] ?? []
                )
            }
            output.append(run)
        }
        return output
    }

    /// Link styling, also applied by text views that would otherwise restyle
    /// link ranges themselves.
    static func linkAttributes() -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: ChatMarkdownAttributedStringBuilder.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
    }
}

private nonisolated struct ChatMarkdownAttributedStringBuilder {
    static let labelColor: ChatPlatformColor = {
        #if os(macOS)
            .labelColor
        #else
            .label
        #endif
    }()

    static let paragraphTerminatorKeys: Set<NSAttributedString.Key> = {
        var keys: Set<NSAttributedString.Key> = [.paragraphStyle, .chatQuoteBarOffsets]
        #if os(iOS)
            keys.insert(.accessibilityTextHeadingLevel)
        #endif
        return keys
    }()

    struct Environment {
        var indent: CGFloat = 0
        var quoteBarOffsets: [CGFloat] = []
        var blockSpacing = ChatMarkdownProseStyle.blockSpacing

        static let root = Environment()
    }

    private struct ListMarker {
        let text: String
        let isBullet: Bool
    }

    private struct InlineStyle {
        var font: ChatPlatformFont
        var color: ChatPlatformColor = ChatMarkdownAttributedStringBuilder.labelColor
        var isBold = false
        var isItalic = false
        var isStruck = false
        var link: URL?
    }

    private let output = NSMutableAttributedString()
    private let source: String
    private var sourceLines: [String]?
    private let bodyFont = ChatPlatformFont.preferredFont(forTextStyle: .body)
    private let bulletFont = ChatPlatformFont.preferredFont(forTextStyle: .headline)
    private let codeFont = ChatPlatformFont.monospacedSystemFont(
        ofSize: ChatPlatformFont.preferredFont(forTextStyle: .callout).pointSize,
        weight: .regular
    )

    init(source: String) {
        self.source = source
    }

    mutating func append(block: Markup, environment: Environment) {
        switch block {
        case let paragraph as Paragraph:
            appendParagraph(
                inlineText(paragraph.children, style: bodyStyle),
                environment: environment
            )

        case let heading as Heading:
            var style = bodyStyle
            style.font = headingFont(level: heading.level)
            style.isBold = true
            appendParagraph(
                inlineText(heading.children, style: style),
                environment: environment,
                accessibilityHeadingLevel: heading.level
            )

        case let quote as BlockQuote:
            var quoted = environment
            quoted.quoteBarOffsets.append(environment.indent)
            quoted.indent +=
                ChatMarkdownProseStyle.quoteBarWidth
                + ChatMarkdownProseStyle.quoteIndent
            for child in quote.children {
                append(block: child, environment: quoted)
            }

        case let list as UnorderedList:
            append(items: list.listItems, environment: environment) { _ in
                ListMarker(
                    text: Self.bullet(for: environment.indent),
                    isBullet: true
                )
            }

        case let list as OrderedList:
            append(items: list.listItems, environment: environment) { offset in
                ListMarker(
                    text: "\(Int(list.startIndex) + offset). ",
                    isBullet: false
                )
            }

        case let thematicBreak as ThematicBreak:
            var style = bodyStyle
            // Retain the source marker for continuous selection/copy;
            // the text host draws its full-width visual representation.
            style.color = .clear
            let text = NSMutableAttributedString(
                attributedString: inlineText(
                    sourceSpelling(for: thematicBreak),
                    style: style
                )
            )
            text.addAttribute(
                .chatThematicBreakIndent,
                value: environment.indent,
                range: NSRange(location: 0, length: text.length)
            )
            appendParagraph(text, environment: environment)

        case let codeBlock as CodeBlock:
            appendParagraph(
                code(codeBlock.code),
                environment: environment
            )

        case let html as HTMLBlock:
            appendParagraph(code(html.rawHTML), environment: environment)

        case let table as Markdown.Table:
            appendParagraph(nestedTable(table), environment: environment)

        default:
            // Preserve any future/custom node instead of dropping it.
            appendParagraph(
                inlineText(block.format(), style: bodyStyle),
                environment: environment
            )
        }
    }

    func finish() -> NSAttributedString {
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(
                in: NSRange(location: output.length - 1, length: 1)
            )
        }
        return NSAttributedString(attributedString: output)
    }

    func inlineText(
        _ nodes: some Sequence<Markup>,
        isBold: Bool
    ) -> NSAttributedString {
        var style = bodyStyle
        style.isBold = isBold
        return inlineText(nodes, style: style)
    }

    func inlineText(_ text: String, isBold: Bool) -> NSAttributedString {
        var style = bodyStyle
        style.isBold = isBold
        return inlineText(text, style: style)
    }

    private var bodyStyle: InlineStyle {
        InlineStyle(font: bodyFont)
    }

    private mutating func append(
        items: some Sequence<ListItem>,
        environment: Environment,
        marker: (Int) -> ListMarker
    ) {
        for (offset, item) in items.enumerated() {
            var isFirstBlock = true
            for child in item.children {
                var nested = environment
                nested.indent += ChatMarkdownProseStyle.listIndent
                nested.blockSpacing = ChatMarkdownProseStyle.listItemSpacing

                if isFirstBlock, let paragraph = child as? Paragraph {
                    let line = NSMutableAttributedString()
                    let listMarker = marker(offset)
                    var markerStyle = bodyStyle
                    if listMarker.isBullet {
                        markerStyle.font = bulletFont
                    }
                    line.append(inlineText(listMarker.text, style: markerStyle))
                    line.append(inlineText(paragraph.children, style: bodyStyle))
                    var first = environment
                    first.blockSpacing = offset == 0
                        ? environment.blockSpacing
                        : ChatMarkdownProseStyle.listItemSpacing
                    appendParagraph(
                        line,
                        environment: first,
                        remainingLineIndent: nested.indent
                    )
                } else {
                    append(block: child, environment: nested)
                }
                isFirstBlock = false
            }
        }
    }

    private mutating func appendParagraph(
        _ text: NSAttributedString,
        environment: Environment,
        remainingLineIndent: CGFloat? = nil,
        accessibilityHeadingLevel: Int? = nil
    ) {
        guard text.length > 0 else { return }
        if output.length > 0 {
            Self.appendBlockSpacer(
                to: output,
                height: environment.blockSpacing,
                connectingTo: environment.quoteBarOffsets
            )
        }

        let start = output.length
        output.append(text)
        output.append(NSAttributedString(string: "\n"))

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ChatMarkdownProseStyle.lineSpacing
        paragraph.firstLineHeadIndent = environment.indent
        paragraph.headIndent = remainingLineIndent ?? environment.indent
        let range = NSRange(location: start, length: output.length - start)
        if !environment.quoteBarOffsets.isEmpty {
            output.addAttribute(
                .chatQuoteBarOffsets,
                value: environment.quoteBarOffsets,
                range: range
            )
        }
        // AppKit has no attributed-string heading-level key; VoiceOver on
        // macOS derives structure from the text view itself.
        #if os(iOS)
            if let accessibilityHeadingLevel {
                output.addAttribute(
                    .accessibilityTextHeadingLevel,
                    value: accessibilityHeadingLevel,
                    range: range
                )
            }
        #endif
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: range
        )
    }

    /// A fixed-height empty line between blocks. Quote bars continue through
    /// it only when the blocks on both sides share them.
    static func appendBlockSpacer(
        to output: NSMutableAttributedString,
        height: CGFloat,
        connectingTo offsets: [CGFloat]
    ) {
        let spacerStart = output.length
        let spacerStyle = NSMutableParagraphStyle()
        spacerStyle.minimumLineHeight = height
        spacerStyle.maximumLineHeight = height
        output.append(
            NSAttributedString(
                string: "\n",
                attributes: [
                    .font: ChatPlatformFont.systemFont(ofSize: 1),
                    .paragraphStyle: spacerStyle,
                ]
            )
        )

        let previousOffsets =
            output.attribute(
                .chatQuoteBarOffsets,
                at: spacerStart - 1,
                effectiveRange: nil
            ) as? [CGFloat] ?? []
        let sharedOffsets = previousOffsets.filter(offsets.contains)
        if !sharedOffsets.isEmpty {
            output.addAttribute(
                .chatQuoteBarOffsets,
                value: sharedOffsets,
                range: NSRange(location: spacerStart, length: 1)
            )
        }
    }

    private static func bullet(for indent: CGFloat) -> String {
        let bullets = ["•", "◦", "▪"]
        let depth = Int(indent / ChatMarkdownProseStyle.listIndent)
        return bullets[depth % bullets.count] + "  "
    }

    private mutating func sourceSpelling(for thematicBreak: ThematicBreak) -> String {
        if sourceLines == nil {
            sourceLines = source.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
        }
        guard let sourceLines,
            let location = thematicBreak.range?.lowerBound,
            sourceLines.indices.contains(location.line - 1)
        else { return thematicBreak.format() }

        let line = Array(sourceLines[location.line - 1].utf8)
        let offset = min(max(0, location.column - 1), line.count)
        return String(decoding: line[offset...], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    private func code(_ text: String) -> NSAttributedString {
        var style = bodyStyle
        style.font = codeFont
        return inlineText(
            text.hasSuffix("\n") ? String(text.dropLast()) : text,
            style: style
        )
    }

    /// A table nested inside a list or quote: one line per row.
    private func nestedTable(_ table: Markdown.Table) -> NSAttributedString {
        var separatorStyle = bodyStyle
        separatorStyle.color = {
            #if os(macOS)
                .secondaryLabelColor
            #else
                .secondaryLabel
            #endif
        }()
        let separator = inlineText("  │  ", style: separatorStyle)
        let rows = [table.head.children.compactMap { $0 as? Markdown.Table.Cell }]
            + table.body.children.compactMap { row in
                (row as? Markdown.Table.Row)?.children.compactMap {
                    $0 as? Markdown.Table.Cell
                }
            }
        let result = NSMutableAttributedString()
        for (rowIndex, cells) in rows.enumerated() {
            if rowIndex > 0 {
                result.append(inlineText("\n", style: bodyStyle))
            }
            for (column, cell) in cells.enumerated() {
                if column > 0 { result.append(separator) }
                result.append(inlineText(cell.children, isBold: rowIndex == 0))
            }
        }
        return result
    }

    private func inlineText(
        _ nodes: some Sequence<Markup>,
        style: InlineStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case let text as Markdown.Text:
                result.append(inlineText(text.string, style: style))
            case let emphasis as Emphasis:
                var nested = style
                nested.isItalic = true
                result.append(inlineText(emphasis.children, style: nested))
            case let strong as Strong:
                var nested = style
                nested.isBold = true
                result.append(inlineText(strong.children, style: nested))
            case let strikethrough as Strikethrough:
                var nested = style
                nested.isStruck = true
                result.append(inlineText(strikethrough.children, style: nested))
            case let code as InlineCode:
                var nested = style
                nested.font = codeFont
                result.append(inlineText(code.code, style: nested))
            case let link as Markdown.Link:
                var nested = style
                nested.link = ChatMarkdownLinkPolicy.url(
                    for: link.destination
                )
                result.append(inlineText(link.children, style: nested))
            case let image as Markdown.Image:
                // Images stay as literal Markdown; never fetch their source.
                var nested = style
                nested.font = codeFont
                result.append(inlineText(image.format(), style: nested))
            case let html as InlineHTML:
                // Inline HTML is inert source text, not executable markup.
                var nested = style
                nested.font = codeFont
                result.append(inlineText(html.rawHTML, style: nested))
            case is SoftBreak:
                // Chat text keeps the line breaks its author typed.
                result.append(inlineText("\n", style: style))
            case is LineBreak:
                result.append(inlineText("\n", style: style))
            default:
                result.append(inlineText(node.format(), style: style))
            }
        }
        return result
    }

    private func inlineText(
        _ text: String,
        style: InlineStyle
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(style),
            .foregroundColor: style.color,
        ]
        if style.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = style.link {
            attributes[.link] = link
            attributes.merge(ChatMarkdownTextRenderer.linkAttributes()) { _, link in link }
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func headingFont(level: Int) -> ChatPlatformFont {
        .preferredFont(
            forTextStyle: ChatMarkdownProseStyle.headingTextStyle(
                level: level
            )
        )
    }

    private func resolvedFont(_ style: InlineStyle) -> ChatPlatformFont {
        guard style.isBold || style.isItalic else { return style.font }
        var traits = style.font.fontDescriptor.symbolicTraits
        #if os(macOS)
            if style.isBold { traits.insert(.bold) }
            if style.isItalic { traits.insert(.italic) }
            let descriptor = style.font.fontDescriptor
                .withSymbolicTraits(traits)
            return NSFont(
                descriptor: descriptor,
                size: style.font.pointSize
            ) ?? style.font
        #else
            if style.isBold { traits.insert(.traitBold) }
            if style.isItalic { traits.insert(.traitItalic) }
            guard
                let descriptor = style.font.fontDescriptor
                    .withSymbolicTraits(traits)
            else { return style.font }
            return UIFont(descriptor: descriptor, size: style.font.pointSize)
        #endif
    }
}
