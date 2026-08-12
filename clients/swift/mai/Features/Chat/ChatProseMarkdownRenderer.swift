#if os(iOS)
    import Markdown
    import UIKit

    extension NSAttributedString.Key {
        nonisolated static let chatQuoteBarOffsets = Self("ChatQuoteBarOffsets")
    }

    /// Converts the prose subset of Markdown into the attributed string used
    /// by the native selectable text view. Rich blocks never enter this path.
    nonisolated enum ChatProseMarkdownRenderer {
        static func attributedString(from source: String) -> NSAttributedString {
            var builder = ChatProseAttributedStringBuilder()
            for block in Markdown.Document(parsing: source).children {
                builder.append(block: block, environment: .root)
            }
            return builder.finish()
        }
    }

    private nonisolated struct ChatProseAttributedStringBuilder {
        struct Environment {
            var indent: CGFloat = 0
            var quoteBarOffsets: [CGFloat] = []
            var color: UIColor = .label
            var blockSpacing = ChatMarkdownProseStyle.blockSpacing

            static let root = Environment()
        }

        private struct ListMarker {
            let text: String
            let isBullet: Bool
        }

        private struct InlineStyle {
            var font: UIFont
            var color: UIColor
            var isBold = false
            var isItalic = false
            var isStruck = false
            var isLink = false
        }

        private let output = NSMutableAttributedString()
        private let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        private let bulletFont = UIFont.preferredFont(forTextStyle: .headline)
        private let codeFont = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .regular
        )

        mutating func append(block: Markup, environment: Environment) {
            switch block {
            case let paragraph as Paragraph:
                appendParagraph(
                    inlineText(paragraph.children, style: inlineStyle(environment)),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent,
                    quoteBarOffsets: environment.quoteBarOffsets,
                    spacingBefore: environment.blockSpacing
                )

            case let heading as Heading:
                var style = inlineStyle(environment)
                style.font = headingFont(level: heading.level)
                style.isBold = true
                appendParagraph(
                    inlineText(heading.children, style: style),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent,
                    quoteBarOffsets: environment.quoteBarOffsets,
                    spacingBefore: environment.blockSpacing,
                    accessibilityHeadingLevel: heading.level
                )

            case let quote as BlockQuote:
                append(quote: quote, environment: environment)

            case let list as UnorderedList:
                append(items: list.listItems, environment: environment) { _, _ in
                    ListMarker(
                        text: Self.bullet(for: environment.indent),
                        isBullet: true
                    )
                }

            case let list as OrderedList:
                append(items: list.listItems, environment: environment) { _, offset in
                    ListMarker(
                        text: "\(Int(list.startIndex) + offset). ",
                        isBullet: false
                    )
                }

            case is ThematicBreak:
                var style = inlineStyle(environment)
                style.color = .secondaryLabel
                appendParagraph(
                    inlineText("⎯⎯⎯⎯⎯", style: style),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent,
                    quoteBarOffsets: environment.quoteBarOffsets,
                    spacingBefore: environment.blockSpacing
                )

            default:
                // The segmenter keeps rich nodes away from this fallback.
                // Formatting an unknown prose node is safer than dropping it.
                appendParagraph(
                    inlineText(block.format(), style: inlineStyle(environment)),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent,
                    quoteBarOffsets: environment.quoteBarOffsets,
                    spacingBefore: environment.blockSpacing
                )
            }
        }

        func finish() -> NSAttributedString {
            while output.string.hasSuffix("\n") {
                output.deleteCharacters(
                    in: NSRange(location: output.length - 1, length: 1)
                )
            }
            return output.copy() as? NSAttributedString
                ?? NSAttributedString(attributedString: output)
        }

        private mutating func append(
            quote: BlockQuote,
            environment: Environment
        ) {
            var quoted = environment
            quoted.quoteBarOffsets.append(environment.indent)
            quoted.indent += ChatMarkdownProseStyle.quoteBarWidth
                + ChatMarkdownProseStyle.quoteIndent

            for child in quote.children {
                if let paragraph = child as? Paragraph {
                    appendParagraph(
                        inlineText(paragraph.children, style: inlineStyle(quoted)),
                        firstLineIndent: quoted.indent,
                        remainingLineIndent: quoted.indent,
                        quoteBarOffsets: quoted.quoteBarOffsets,
                        spacingBefore: quoted.blockSpacing
                    )
                } else {
                    append(block: child, environment: quoted)
                }
            }
        }

        private mutating func append(
            items: some Sequence<ListItem>,
            environment: Environment,
            marker: (ListItem, Int) -> ListMarker
        ) {
            for (offset, item) in items.enumerated() {
                var isFirstBlock = true
                for child in item.children {
                    var nested = environment
                    nested.indent += ChatMarkdownProseStyle.listIndent
                    nested.blockSpacing = ChatMarkdownProseStyle.listItemSpacing

                    if isFirstBlock, let paragraph = child as? Paragraph {
                        let line = NSMutableAttributedString()
                        let listMarker = marker(item, offset)
                        var markerStyle = inlineStyle(environment)
                        if listMarker.isBullet {
                            markerStyle.font = bulletFont
                        }
                        line.append(
                            inlineText(listMarker.text, style: markerStyle)
                        )
                        line.append(
                            inlineText(paragraph.children, style: inlineStyle(environment))
                        )
                        appendParagraph(
                            line,
                            firstLineIndent: environment.indent,
                            remainingLineIndent: nested.indent,
                            quoteBarOffsets: environment.quoteBarOffsets,
                            spacingBefore: offset == 0
                                ? environment.blockSpacing
                                : ChatMarkdownProseStyle.listItemSpacing
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
            firstLineIndent: CGFloat,
            remainingLineIndent: CGFloat,
            quoteBarOffsets: [CGFloat] = [],
            spacingBefore: CGFloat,
            accessibilityHeadingLevel: Int? = nil
        ) {
            guard text.length > 0 else { return }
            appendBlockSpacer(
                height: spacingBefore,
                connectingTo: quoteBarOffsets
            )

            let start = output.length
            output.append(text)
            output.append(NSAttributedString(string: "\n"))

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = ChatMarkdownProseStyle.lineSpacing
            paragraph.firstLineHeadIndent = firstLineIndent
            paragraph.headIndent = remainingLineIndent
            let range = NSRange(location: start, length: output.length - start)
            if !quoteBarOffsets.isEmpty {
                output.addAttribute(
                    .chatQuoteBarOffsets,
                    value: quoteBarOffsets,
                    range: range
                )
            }
            if let accessibilityHeadingLevel {
                output.addAttribute(
                    .accessibilityTextHeadingLevel,
                    value: accessibilityHeadingLevel,
                    range: range
                )
            }
            output.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: range
            )
        }

        private func appendBlockSpacer(
            height: CGFloat,
            connectingTo offsets: [CGFloat]
        ) {
            guard output.length > 0 else { return }

            let spacerStart = output.length
            let spacerStyle = NSMutableParagraphStyle()
            spacerStyle.minimumLineHeight = height
            spacerStyle.maximumLineHeight = height
            output.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 1),
                        .paragraphStyle: spacerStyle,
                    ]
                )
            )

            let previousOffsets = output.attribute(
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

        private func inlineStyle(_ environment: Environment) -> InlineStyle {
            InlineStyle(font: bodyFont, color: environment.color)
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
                    nested.isLink = true
                    result.append(inlineText(link.children, style: nested))
                case is SoftBreak:
                    result.append(inlineText(" ", style: style))
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
            if style.isLink {
                // Display-only, matching the chat's discarded OpenURLAction.
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: text, attributes: attributes)
        }

        private func headingFont(level: Int) -> UIFont {
            .preferredFont(
                forTextStyle: ChatMarkdownProseStyle.headingTextStyle(
                    level: level
                )
            )
        }

        private func resolvedFont(_ style: InlineStyle) -> UIFont {
            guard style.isBold || style.isItalic else { return style.font }
            var traits = style.font.fontDescriptor.symbolicTraits
            if style.isBold { traits.insert(.traitBold) }
            if style.isItalic { traits.insert(.traitItalic) }
            guard let descriptor = style.font.fontDescriptor.withSymbolicTraits(traits)
            else { return style.font }
            return UIFont(descriptor: descriptor, size: style.font.pointSize)
        }
    }
#endif
