#if os(iOS)
    import Markdown
    import UIKit

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
            var color: UIColor = .label
            var usesSerifBody = false

            static let root = Environment()
        }

        private struct InlineStyle {
            var font: UIFont
            var color: UIColor
            var isBold = false
            var isItalic = false
            var isStruck = false
            var isLink = false
        }

        private static let blockSpacing: CGFloat = 8
        private static let lineSpacing: CGFloat = 2
        private static let listIndent: CGFloat = 20
        private static let quoteIndent: CGFloat = 12

        private let output = NSMutableAttributedString()
        private let bodyFont = UIFont.preferredFont(forTextStyle: .body)
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
                    remainingLineIndent: environment.indent
                )

            case let heading as Heading:
                var style = inlineStyle(environment)
                style.font = headingFont(level: heading.level)
                appendParagraph(
                    inlineText(heading.children, style: style),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent
                )

            case let quote as BlockQuote:
                var quoted = environment
                quoted.indent += Self.quoteIndent
                quoted.color = .secondaryLabel
                quoted.usesSerifBody = true
                for child in quote.children {
                    append(block: child, environment: quoted)
                }

            case let list as UnorderedList:
                append(items: list.listItems, environment: environment) { item, _ in
                    item.checkbox.map { $0 == .checked ? "☑ " : "☐ " }
                        ?? Self.bullet(for: environment.indent)
                }

            case let list as OrderedList:
                append(items: list.listItems, environment: environment) { _, offset in
                    "\(Int(list.startIndex) + offset). "
                }

            case is ThematicBreak:
                var style = inlineStyle(environment)
                style.color = .secondaryLabel
                appendParagraph(
                    inlineText("⎯⎯⎯⎯⎯", style: style),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent
                )

            default:
                // The segmenter keeps rich nodes away from this fallback.
                // Formatting an unknown prose node is safer than dropping it.
                appendParagraph(
                    inlineText(block.format(), style: inlineStyle(environment)),
                    firstLineIndent: environment.indent,
                    remainingLineIndent: environment.indent
                )
            }
        }

        func finish() -> NSAttributedString {
            while output.string.hasSuffix("\n") {
                output.deleteCharacters(
                    in: NSRange(location: output.length - 1, length: 1)
                )
            }
            return output
        }

        private mutating func append(
            items: some Sequence<ListItem>,
            environment: Environment,
            marker: (ListItem, Int) -> String
        ) {
            for (offset, item) in items.enumerated() {
                var isFirstBlock = true
                for child in item.children {
                    var nested = environment
                    nested.indent += Self.listIndent

                    if isFirstBlock, let paragraph = child as? Paragraph {
                        let line = NSMutableAttributedString()
                        line.append(
                            inlineText(marker(item, offset), style: inlineStyle(environment))
                        )
                        line.append(
                            inlineText(paragraph.children, style: inlineStyle(environment))
                        )
                        appendParagraph(
                            line,
                            firstLineIndent: environment.indent,
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
            firstLineIndent: CGFloat,
            remainingLineIndent: CGFloat
        ) {
            guard text.length > 0 else { return }
            let start = output.length
            output.append(text)
            output.append(NSAttributedString(string: "\n"))

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = Self.lineSpacing
            paragraph.paragraphSpacing = Self.blockSpacing
            paragraph.firstLineHeadIndent = firstLineIndent
            paragraph.headIndent = remainingLineIndent
            output.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: start, length: output.length - start)
            )
        }

        private static func bullet(for indent: CGFloat) -> String {
            let bullets = ["•", "◦", "▪"]
            let depth = Int(indent / Self.listIndent)
            return bullets[depth % bullets.count] + "  "
        }

        private func inlineStyle(_ environment: Environment) -> InlineStyle {
            InlineStyle(
                font: environment.usesSerifBody ? serifBodyFont : bodyFont,
                color: environment.color
            )
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
                    result.append(inlineText(code.code, style: nested, isCode: true))
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
            style: InlineStyle,
            isCode: Bool = false
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
            if isCode {
                attributes[.backgroundColor] = UIColor.label.withAlphaComponent(0.08)
            }
            return NSAttributedString(string: text, attributes: attributes)
        }

        private func headingFont(level: Int) -> UIFont {
            let styles: [UIFont.TextStyle] = [
                .largeTitle, .title1, .title2, .title3, .headline,
            ]
            let index = max(1, min(6, level)) - 1
            if styles.indices.contains(index) {
                return .preferredFont(forTextStyle: styles[index])
            }
            return .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize,
                weight: .regular
            )
        }

        private var serifBodyFont: UIFont {
            guard let descriptor = bodyFont.fontDescriptor.withDesign(.serif) else {
                return bodyFont
            }
            return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
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
