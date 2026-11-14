import SwiftUI

/// Attributed content and exact measurement for one prose segment.
/// The background TextKit graph is used only for measurement: every visible
/// text view owns its display graph. AppKit requires one view per text
/// container, and a UITextView handed a measured stack invalidates it and
/// lays the whole string out again. Decoration geometry is captured here so
/// drawing never re-walks the attributed string.
nonisolated final class ChatTextLayout: @unchecked Sendable {
    let width: CGFloat
    let height: CGFloat
    /// Width the laid-out lines actually occupy. Equals `width` for
    /// wrapped prose; meaningful for unwrapped code laid out unbounded.
    let contentWidth: CGFloat
    let attributedString: NSAttributedString
    let quoteBarRects: [CGRect]
    let thematicBreakRects: [CGRect]
    let hasMarkdownDecorations: Bool

    convenience init(content: ChatTextContent, width: CGFloat) {
        self.init(attributedString: content.attributedString, width: width)
    }

    /// Unwrapped code: lines run to their natural width and the host
    /// scrolls horizontally.
    convenience init(code: NSAttributedString) {
        self.init(
            attributedString: code,
            width: .greatestFiniteMagnitude
        )
    }

    private init(
        attributedString: NSAttributedString,
        width: CGFloat
    ) {
        let safeWidth = max(1, width)
        let storage = NSTextStorage(attributedString: attributedString)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(
                width: safeWidth,
                height: .greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var rangesByOffset: [CGFloat: [NSRange]] = [:]
        var index = 0
        while index < attributedString.length {
            var range = NSRange()
            let offsets =
                attributedString.attribute(
                    .chatQuoteBarOffsets,
                    at: index,
                    effectiveRange: &range
                ) as? [CGFloat] ?? []
            index = NSMaxRange(range)

            for offset in offsets {
                var ranges = rangesByOffset[offset, default: []]
                if let previous = ranges.last,
                    NSMaxRange(previous) == range.location
                {
                    ranges[ranges.count - 1] = NSUnionRange(previous, range)
                } else {
                    ranges.append(range)
                }
                rangesByOffset[offset] = ranges
            }
        }

        var quoteBarRects: [CGRect] = []
        for (offset, ranges) in rangesByOffset {
            for range in ranges {
                let glyphRange = manager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                let bounds = manager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: container
                )
                quoteBarRects.append(
                    CGRect(
                        x: offset,
                        y: bounds.minY,
                        width: ChatMarkdownProseStyle.quoteBarWidth,
                        height: bounds.height
                    )
                )
            }
        }

        var thematicBreakRects: [CGRect] = []
        attributedString.enumerateAttribute(
            .chatThematicBreakIndent,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let indent = value as? CGFloat else { return }
            let glyphRange = manager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }
            let line = manager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            thematicBreakRects.append(
                CGRect(
                    x: indent,
                    y: line.midY,
                    width: max(0, container.size.width - indent),
                    height: 1
                )
            )
        }

        let usedRect = manager.usedRect(for: container)
        self.width = safeWidth
        self.height = ceil(max(1, usedRect.height))
        self.contentWidth = ceil(usedRect.width)
        self.attributedString = attributedString
        self.quoteBarRects = quoteBarRects
        self.thematicBreakRects = thematicBreakRects
        self.hasMarkdownDecorations =
            !quoteBarRects.isEmpty || !thematicBreakRects.isEmpty
    }
}
