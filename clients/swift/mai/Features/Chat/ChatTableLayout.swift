import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Cell text, cell frames, and dividers for one Markdown table, measured
/// off the main actor. Columns are sized to content between 96 and 280
/// points, with 24 points between columns, 12 points above and below each
/// row, and a hairline between rows.
nonisolated final class ChatTableLayout: @unchecked Sendable {
    struct Cell {
        let text: NSAttributedString
        let frame: CGRect
    }

    static let minimumColumnWidth: CGFloat = 96
    static let maximumColumnWidth: CGFloat = 280
    static let columnSpacing: CGFloat = 24
    static let verticalPadding: CGFloat = 12
    static let dividerHeight: CGFloat = 1

    let size: CGSize
    let cells: [Cell]
    let dividerRects: [CGRect]

    init(table: ChatMarkdownTable) {
        let columnCount = table.columnCount
        let rows = [table.header] + table.rows

        // Measure every cell once at the widest column allowed. The
        // final column is at least as wide as its widest cell, so no
        // cell rewraps when drawn.
        var measured: [[(text: NSAttributedString, size: CGSize)]] = []
        var columnWidths = [CGFloat](
            repeating: Self.minimumColumnWidth,
            count: columnCount
        )
        for row in rows {
            var measuredRow: [(NSAttributedString, CGSize)] = []
            for column in 0..<columnCount {
                let text = Self.cellText(
                    row.indices.contains(column) ? row[column] : nil,
                    alignment: table.alignments.indices.contains(column)
                        ? table.alignments[column] : .leading
                )
                let size = Self.measure(text)
                columnWidths[column] = max(columnWidths[column], size.width)
                measuredRow.append((text, size))
            }
            measured.append(measuredRow)
        }

        var columnOrigins: [CGFloat] = []
        var x: CGFloat = 0
        for width in columnWidths {
            columnOrigins.append(x)
            x += width + Self.columnSpacing
        }
        let tableWidth = max(0, x - Self.columnSpacing)

        var cells: [Cell] = []
        var dividerRects: [CGRect] = []
        var y: CGFloat = 0
        for (rowIndex, row) in measured.enumerated() {
            let rowHeight = row.map(\.size.height).max() ?? 0
            for (column, cell) in row.enumerated() {
                cells.append(
                    Cell(
                        text: cell.text,
                        frame: CGRect(
                            x: columnOrigins[column],
                            y: y + Self.verticalPadding,
                            width: columnWidths[column],
                            height: cell.size.height
                        )
                    )
                )
            }
            y += rowHeight + 2 * Self.verticalPadding
            if rowIndex < measured.count - 1 {
                dividerRects.append(
                    CGRect(
                        x: 0,
                        y: y,
                        width: tableWidth,
                        height: Self.dividerHeight
                    )
                )
                y += Self.dividerHeight
            }
        }

        size = CGSize(width: tableWidth, height: y)
        self.cells = cells
        self.dividerRects = dividerRects
    }

    private static func cellText(
        _ value: ChatMarkdownText?,
        alignment: ChatMarkdownTable.ColumnAlignment
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: value?.value ?? NSAttributedString()
        )
        let range = NSRange(location: 0, length: text.length)
        #if os(macOS)
            // Drawn cells are not interactive. AppKit would otherwise replace
            // the renderer's link styling with its own link color.
            text.removeAttribute(.link, range: range)
        #endif
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment =
            switch alignment {
            case .leading: .left
            case .center: .center
            case .trailing: .right
            }
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return text
    }

    private static func measure(_ text: NSAttributedString) -> CGSize {
        guard text.length > 0 else {
            #if os(macOS)
                let lineHeight = NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height
            #else
                let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
            #endif
            return CGSize(width: 0, height: ceil(lineHeight))
        }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: maximumColumnWidth, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    #if os(iOS)
        /// The link under `point`, in table coordinates. Cells are drawn, not
        /// hosted in text views, so a tap is resolved against a layout of the
        /// one cell it landed in.
        func link(at point: CGPoint) -> URL? {
            guard let cell = cells.first(where: { $0.frame.contains(point) }),
                cell.text.length > 0
            else { return nil }
            let storage = NSTextStorage(attributedString: cell.text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: cell.frame.width, height: .greatestFiniteMagnitude)
            )
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)

            let local = CGPoint(x: point.x - cell.frame.minX, y: point.y - cell.frame.minY)
            let glyph = manager.glyphIndex(for: local, in: container)
            // `glyphIndex(for:in:)` returns the nearest glyph; a tap in the
            // cell's empty space must not open a neighboring link.
            guard manager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1),
                in: container
            ).contains(local) else { return nil }
            let character = manager.characterIndexForGlyph(at: glyph)
            return storage.attribute(.link, at: character, effectiveRange: nil) as? URL
        }
    #endif
}
