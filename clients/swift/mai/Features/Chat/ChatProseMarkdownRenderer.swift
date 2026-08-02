import Foundation
import Markdown

#if canImport(UIKit)
    import UIKit
    typealias ChatProsePlatformFont = UIFont
    typealias ChatProsePlatformColor = UIColor
#elseif canImport(AppKit)
    import AppKit
    typealias ChatProsePlatformFont = NSFont
    typealias ChatProsePlatformColor = NSColor
#endif

/// Renders a prose-only markdown segment (paragraphs, headings, lists,
/// quotes, breaks — no code fences, tables, HTML, images, or math; the
/// segmenter guarantees that) into one attributed string, so a whole prose
/// run can live in a single selectable text view laid out off the main
/// thread.
///
/// Styling mirrors MarkdownView's defaults (font group, 8pt block spacing,
/// 2pt line spacing, primary-tinted display-only links) closely enough that
/// the swap from the streaming MarkdownView renderer to this one at
/// turn-settle reads as the same message.
nonisolated enum ChatProseMarkdownRenderer {
    static func attributedString(from source: String) -> NSAttributedString {
        var builder = ChatProseBuilder()
        for block in Markdown.Document(parsing: source).children {
            builder.append(block: block, environment: .root)
        }
        return builder.finish()
    }
}

private nonisolated struct ChatProseBuilder {
    /// Inherited styling for nested structures (list items, quotes).
    struct Environment {
        var indent: CGFloat = 0
        var foreground: ChatProsePlatformColor = .chatProseLabel
        var usesSerifBody = false

        static let root = Environment()
    }

    private struct InlineStyle {
        var font: ChatProsePlatformFont
        var foreground: ChatProsePlatformColor
        var bold = false
        var italic = false
        var strikethrough = false
        var isLink = false
    }

    private static let blockSpacing: CGFloat = 8
    private static let lineSpacing: CGFloat = 2
    private static let listIndentStep: CGFloat = 20
    private static let quoteIndentStep: CGFloat = 12

    private let output = NSMutableAttributedString()
    private let bodyFont = ChatProsePlatformFont.preferredFont(forTextStyle: .body)
    private let codeFont = ChatProsePlatformFont.monospacedSystemFont(
        ofSize: ChatProsePlatformFont.preferredFont(forTextStyle: .callout).pointSize,
        weight: .regular
    )

    mutating func append(block: Markup, environment: Environment) {
        switch block {
        case let paragraph as Paragraph:
            appendLine(
                inlineText(paragraph.children, style: inlineStyle(environment)),
                indent: environment.indent,
                hangingIndent: environment.indent
            )
        case let heading as Heading:
            var style = inlineStyle(environment)
            style.font = headingFont(level: heading.level)
            appendLine(
                inlineText(heading.children, style: style),
                indent: environment.indent,
                hangingIndent: environment.indent
            )
        case let quote as BlockQuote:
            var quoted = environment
            quoted.indent += Self.quoteIndentStep
            quoted.foreground = .chatProseSecondaryLabel
            quoted.usesSerifBody = true
            for child in quote.children {
                append(block: child, environment: quoted)
            }
        case let list as UnorderedList:
            append(items: list.listItems, environment: environment) { item, _ in
                item.checkbox.map { $0 == .checked ? "☑ " : "☐ " }
                    ?? Self.bulletMarker(for: environment.indent)
            }
        case let list as OrderedList:
            append(items: list.listItems, environment: environment) { _, offset in
                "\(Int(list.startIndex) + offset). "
            }
        case is ThematicBreak:
            var style = inlineStyle(environment)
            style.foreground = .chatProseSecondaryLabel
            appendLine(
                inlineText(text: "⎯⎯⎯⎯⎯", style: style),
                indent: environment.indent,
                hangingIndent: environment.indent
            )
        default:
            // Unknown block kinds keep their literal markdown so no content
            // is dropped; the segmenter keeps rich kinds out of prose runs.
            appendLine(
                inlineText(text: block.format(), style: inlineStyle(environment)),
                indent: environment.indent,
                hangingIndent: environment.indent
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

    // MARK: Blocks

    private mutating func append(
        items: some Sequence<ListItem>,
        environment: Environment,
        marker: (ListItem, Int) -> String
    ) {
        for (offset, item) in items.enumerated() {
            var isFirstBlock = true
            for child in item.children {
                var nested = environment
                nested.indent += Self.listIndentStep

                if isFirstBlock, let paragraph = child as? Paragraph {
                    let line = NSMutableAttributedString()
                    line.append(
                        inlineText(
                            text: marker(item, offset),
                            style: inlineStyle(environment)
                        )
                    )
                    line.append(
                        inlineText(
                            paragraph.children,
                            style: inlineStyle(environment)
                        )
                    )
                    appendLine(
                        line,
                        indent: environment.indent,
                        hangingIndent: nested.indent
                    )
                } else {
                    append(block: child, environment: nested)
                }
                isFirstBlock = false
            }
        }
    }

    /// Appends one rendered block plus its terminating newline, then applies
    /// the paragraph style across the whole block so spacing and indentation
    /// cover every wrapped line.
    private mutating func appendLine(
        _ text: NSAttributedString,
        indent: CGFloat,
        hangingIndent: CGFloat
    ) {
        guard text.length > 0 else { return }
        let start = output.length
        output.append(text)
        output.append(NSAttributedString(string: "\n"))

        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing
        style.paragraphSpacing = Self.blockSpacing
        style.firstLineHeadIndent = indent
        style.headIndent = hangingIndent
        output.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: start, length: output.length - start)
        )
    }

    private static func bulletMarker(for indent: CGFloat) -> String {
        let depth = Int(indent / Self.listIndentStep)
        let bullets = ["•", "◦", "▪"]
        return bullets[depth % bullets.count] + "  "
    }

    // MARK: Inline content

    private func inlineStyle(_ environment: Environment) -> InlineStyle {
        InlineStyle(
            font: environment.usesSerifBody ? serifBodyFont : bodyFont,
            foreground: environment.foreground
        )
    }

    private func inlineText(
        _ inlines: some Sequence<Markup>,
        style: InlineStyle
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for inline in inlines {
            switch inline {
            case let plain as Markdown.Text:
                text.append(inlineText(text: plain.string, style: style))
            case let emphasis as Emphasis:
                var italic = style
                italic.italic = true
                text.append(inlineText(emphasis.children, style: italic))
            case let strong as Strong:
                var bold = style
                bold.bold = true
                text.append(inlineText(strong.children, style: bold))
            case let strikethrough as Strikethrough:
                var struck = style
                struck.strikethrough = true
                text.append(inlineText(strikethrough.children, style: struck))
            case let code as InlineCode:
                var mono = style
                mono.font = codeFont
                text.append(
                    inlineText(text: code.code, style: mono, isCode: true)
                )
            case let link as Markdown.Link:
                // Display-only, matching the chat's discarded OpenURLAction:
                // styled as a link but carrying no interactive attribute.
                var linked = style
                linked.isLink = true
                text.append(inlineText(link.children, style: linked))
            case is SoftBreak:
                text.append(inlineText(text: " ", style: style))
            case is LineBreak:
                text.append(inlineText(text: "\n", style: style))
            default:
                text.append(inlineText(text: inline.format(), style: style))
            }
        }
        return text
    }

    private func inlineText(
        text: String,
        style: InlineStyle,
        isCode: Bool = false
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(style),
            .foregroundColor: style.foreground,
        ]
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if isCode {
            attributes[.backgroundColor] = ChatProsePlatformColor.chatProseCodeBackground
        }
        if style.isLink {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    // MARK: Fonts

    /// MarkdownView's default font group: largeTitle, title1, title2,
    /// title3, headline, then headline-sized regular.
    private func headingFont(level: Int) -> ChatProsePlatformFont {
        let styles: [ChatProsePlatformFont.TextStyle] = [
            .largeTitle, .title1, .title2, .title3, .headline,
        ]
        let index = max(1, min(6, level)) - 1
        if index < styles.count {
            return .preferredFont(forTextStyle: styles[index])
        }
        return .systemFont(
            ofSize: ChatProsePlatformFont.preferredFont(forTextStyle: .headline).pointSize,
            weight: .regular
        )
    }

    private var serifBodyFont: ChatProsePlatformFont {
        #if canImport(UIKit)
            guard let descriptor = bodyFont.fontDescriptor.withDesign(.serif) else {
                return bodyFont
            }
            return ChatProsePlatformFont(descriptor: descriptor, size: bodyFont.pointSize)
        #else
            guard let descriptor = bodyFont.fontDescriptor.withDesign(.serif) else {
                return bodyFont
            }
            return ChatProsePlatformFont(descriptor: descriptor, size: bodyFont.pointSize)
                ?? bodyFont
        #endif
    }

    private func resolvedFont(_ style: InlineStyle) -> ChatProsePlatformFont {
        guard style.bold || style.italic else { return style.font }
        #if canImport(UIKit)
            var traits = style.font.fontDescriptor.symbolicTraits
            if style.bold { traits.insert(.traitBold) }
            if style.italic { traits.insert(.traitItalic) }
            guard let descriptor = style.font.fontDescriptor.withSymbolicTraits(traits)
            else { return style.font }
            return ChatProsePlatformFont(descriptor: descriptor, size: style.font.pointSize)
        #else
            var traits = style.font.fontDescriptor.symbolicTraits
            if style.bold { traits.insert(.bold) }
            if style.italic { traits.insert(.italic) }
            let descriptor = style.font.fontDescriptor.withSymbolicTraits(traits)
            return ChatProsePlatformFont(descriptor: descriptor, size: style.font.pointSize)
                ?? style.font
        #endif
    }
}

extension ChatProsePlatformColor {
    fileprivate nonisolated static var chatProseLabel: ChatProsePlatformColor {
        #if canImport(UIKit)
            .label
        #else
            .labelColor
        #endif
    }

    fileprivate nonisolated static var chatProseSecondaryLabel: ChatProsePlatformColor {
        #if canImport(UIKit)
            .secondaryLabel
        #else
            .secondaryLabelColor
        #endif
    }

    fileprivate nonisolated static var chatProseCodeBackground: ChatProsePlatformColor {
        chatProseLabel.withAlphaComponent(0.08)
    }
}
