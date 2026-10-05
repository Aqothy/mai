#if os(macOS)
    import AppKit
    import SwiftUI

    // Native macOS rendering for settled rich Markdown blocks.
    //
    // A List row on macOS is already an `NSHostingView`; nesting another
    // hosting view per code block or table (the previous
    // `ChatMacHorizontalScrollView`) made every realized row run a second
    // SwiftUI graph, Auto Layout constraint pass, and `fittingSize` query on
    // the main thread. Profiling a 3,000 pt/s sweep put that at roughly a
    // fifth of the main thread's busy time. These views instead present a
    // layout measured off the main actor by `ChatTextLayoutStore`, so row
    // realization is a frame assignment and the row's height is known before
    // the row exists.

    // MARK: - Code blocks

    /// Typography for fenced code on macOS. Mirrors the SwiftUI presentation
    /// (`.callout.monospaced()` with 4 pt line spacing) used on iOS.
    nonisolated enum ChatMacCodeStyle {
        static let horizontalInset: CGFloat = 16
        static let bottomInset: CGFloat = 16
        static let lineSpacing: CGFloat = 4

        static var font: NSFont {
            NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: .regular
            )
        }

        static func attributedString(code: String) -> NSMutableAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            return NSMutableAttributedString(
                string: code,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }

        /// Overlays syntax colors on `code`'s plain attributed form. The
        /// highlighter only contributes foreground colors, so line metrics
        /// (and therefore the prepared row height) are unchanged. A
        /// highlighter result whose text differs from the source is ignored
        /// rather than risking mismatched ranges.
        static func highlightedAttributedString(
            block: ChatMarkdownCodeBlock,
            theme: ChatCodeHighlightTheme
        ) async -> NSMutableAttributedString {
            let base = attributedString(code: block.code)
            guard
                let highlighted = await ChatCodeHighlighter.shared.highlight(
                    code: block.code,
                    language: block.language,
                    theme: theme
                ),
                let colored = try? NSAttributedString(
                    highlighted,
                    including: \.appKit
                ),
                colored.string == base.string
            else { return base }

            colored.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: colored.length)
            ) { value, range, _ in
                guard let color = value as? NSColor else { return }
                base.addAttribute(.foregroundColor, value: color, range: range)
            }
            return base
        }
    }

    /// A fenced code block as one selectable, horizontally scrolling
    /// `NSTextView` whose text and size were prepared off the main actor.
    struct ChatMacCodeBlockText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let block: ChatMarkdownCodeBlock
        let theme: ChatCodeHighlightTheme
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatMacCodeBlockHostView {
            ChatMacCodeBlockHostView()
        }

        func updateNSView(
            _ nsView: ChatMacCodeBlockHostView,
            context: Context
        ) {
            (nsView.documentView as? ChatAnnotationTextView)?.annotationContext = annotationContext
            nsView.update(
                layoutID: layoutID,
                block: block,
                theme: theme,
                layoutStore: layoutStore
            )
        }

        static func dismantleNSView(
            _ nsView: ChatMacCodeBlockHostView,
            coordinator: Void
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatMacCodeBlockHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.codeLayout(
                id: layoutID,
                block: block,
                theme: theme
            ).layout
            return CGSize(
                width: width,
                height: layout.height + ChatMacCodeStyle.bottomInset
            )
        }
    }

    final class ChatMacCodeBlockHostView: ChatMacHorizontalDocumentScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private let textView: NSTextView
        private var layoutID: String?
        private var block: ChatMarkdownCodeBlock?
        private var theme: ChatCodeHighlightTheme?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var highlightTask: Task<Void, Never>?

        override init(frame frameRect: NSRect) {
            textView = ChatSelectableTextViewConfiguration.makeTextView()
            super.init(frame: frameRect)
            textView.textContainerInset = NSSize(
                width: ChatMacCodeStyle.horizontalInset,
                height: 0
            )
            // Code never wraps; the container scrolls horizontally instead.
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = false
            documentView = textView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            layoutID: String,
            block: ChatMarkdownCodeBlock,
            theme: ChatCodeHighlightTheme,
            layoutStore: ChatTextLayoutStore
        ) {
            guard self.layoutID != layoutID || self.block != block
                || self.theme != theme || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.block = block
            self.theme = theme
            self.layoutStore = layoutStore
            highlightTask?.cancel()
            highlightTask = nil
            needsLayout = true
        }

        func dismantle() {
            (textView as? ChatAnnotationTextView)?.annotationContext = nil
            highlightTask?.cancel()
            highlightTask = nil
            presentedLayout = nil
            layoutID = nil
            block = nil
            layoutStore = nil
        }

        override func layout() {
            if let layoutID, let block, let theme, let layoutStore {
                let (layout, isHighlighted) = layoutStore.codeLayout(
                    id: layoutID,
                    block: block,
                    theme: theme
                )
                if presentedLayout !== layout {
                    present(layout)
                }
                // A row realized before its page was prepared shows plain
                // text now and receives colors when the highlighter finishes.
                if !isHighlighted, highlightTask == nil {
                    let request = ChatCodeLayoutRequest(
                        id: layoutID,
                        block: block,
                        theme: theme
                    )
                    highlightTask = Task { [weak self, weak layoutStore] in
                        await layoutStore?.prepareCodeBlocks(requests: [request])
                        guard let self, !Task.isCancelled,
                            self.layoutID == request.id, self.block == request.block
                        else { return }
                        self.highlightTask = nil
                        self.needsLayout = true
                    }
                }
            }
            super.layout()
        }

        private func present(_ layout: ChatTextLayout) {
            textView.textStorage?.setAttributedString(layout.attributedString)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            presentedLayout = layout
            documentSize = NSSize(
                width: layout.contentWidth + 2 * ChatMacCodeStyle.horizontalInset,
                height: layout.height + ChatMacCodeStyle.bottomInset
            )
        }
    }

    // MARK: - Tables

    /// Cell text, cell frames, and dividers for one Markdown table, measured
    /// off the main actor. Matches the SwiftUI grid: columns sized to
    /// content between 96 and 280 points, 24 points between columns, 12
    /// points above and below each row, and a hairline between rows.
    nonisolated final class ChatTableLayout: @unchecked Sendable {
        struct Cell {
            let text: NSAttributedString
            let frame: NSRect
        }

        static let minimumColumnWidth: CGFloat = 96
        static let maximumColumnWidth: CGFloat = 280
        static let columnSpacing: CGFloat = 24
        static let verticalPadding: CGFloat = 12
        static let dividerHeight: CGFloat = 1

        let size: NSSize
        let cells: [Cell]
        let dividerRects: [NSRect]

        init(table: ChatMarkdownTable) {
            let columnCount = table.columnCount
            let rows = [table.header] + table.rows

            // Measure every cell once at the widest column allowed. The
            // final column is at least as wide as its widest cell, so no
            // cell rewraps when drawn.
            var measured: [[(text: NSAttributedString, size: NSSize)]] = []
            var columnWidths = [CGFloat](
                repeating: Self.minimumColumnWidth,
                count: columnCount
            )
            for (rowIndex, row) in rows.enumerated() {
                var measuredRow: [(NSAttributedString, NSSize)] = []
                for column in 0..<columnCount {
                    let text = Self.cellText(
                        row.indices.contains(column) ? row[column] : AttributedString(),
                        alignment: table.alignments.indices.contains(column)
                            ? table.alignments[column] : .leading,
                        isHeader: rowIndex == 0
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
            var dividerRects: [NSRect] = []
            var y: CGFloat = 0
            for (rowIndex, row) in measured.enumerated() {
                let rowHeight = row.map(\.size.height).max() ?? 0
                for (column, cell) in row.enumerated() {
                    cells.append(
                        Cell(
                            text: cell.text,
                            frame: NSRect(
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
                        NSRect(
                            x: 0,
                            y: y,
                            width: tableWidth,
                            height: Self.dividerHeight
                        )
                    )
                    y += Self.dividerHeight
                }
            }

            size = NSSize(width: tableWidth, height: y)
            self.cells = cells
            self.dividerRects = dividerRects
        }

        private static func cellText(
            _ value: AttributedString,
            alignment: ChatMarkdownTable.ColumnAlignment,
            isHeader: Bool
        ) -> NSAttributedString {
            let text = ChatTextLayout.inlineAttributedString(from: value)
            if isHeader {
                text.enumerateAttribute(
                    .font,
                    in: NSRange(location: 0, length: text.length)
                ) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    text.addAttribute(
                        .font,
                        value: NSFontManager.shared.convert(
                            font,
                            toHaveTrait: .boldFontMask
                        ),
                        range: range
                    )
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment =
                switch alignment {
                case .leading: .left
                case .center: .center
                case .trailing: .right
                }
            text.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: text.length)
            )
            return text
        }

        private static func measure(_ text: NSAttributedString) -> NSSize {
            guard text.length > 0 else {
                return NSSize(
                    width: 0,
                    height: ceil(NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height)
                )
            }
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(
                containerSize: NSSize(
                    width: maximumColumnWidth,
                    height: .greatestFiniteMagnitude
                )
            )
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            return NSSize(width: ceil(used.width), height: ceil(used.height))
        }
    }

    /// A Markdown table drawn from a prepared `ChatTableLayout` inside the
    /// horizontal scroller. Cells are deliberately not selectable; the copy
    /// button above the table copies it whole.
    struct ChatMacTableBlock: NSViewRepresentable {
        let layoutID: String
        let table: ChatMarkdownTable
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatMacTableHostView {
            ChatMacTableHostView()
        }

        func updateNSView(_ nsView: ChatMacTableHostView, context: Context) {
            nsView.update(
                layoutID: layoutID,
                table: table,
                layoutStore: layoutStore
            )
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatMacTableHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.tableLayout(id: layoutID, table: table)
            return CGSize(width: width, height: layout.size.height)
        }
    }

    final class ChatMacTableHostView: ChatMacHorizontalDocumentScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private final class TableDocumentView: NSView {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            var tableLayout: ChatTableLayout? {
                didSet { needsDisplay = true }
            }

            override var isFlipped: Bool { true }

            override func draw(_ dirtyRect: NSRect) {
                guard let tableLayout else { return }
                for cell in tableLayout.cells where cell.frame.intersects(dirtyRect) {
                    cell.text.draw(
                        with: cell.frame,
                        options: [.usesLineFragmentOrigin]
                    )
                }
                NSColor.separatorColor.setFill()
                for rect in tableLayout.dividerRects where rect.intersects(dirtyRect) {
                    rect.fill()
                }
            }
        }

        private let tableView = TableDocumentView()
        private var layoutID: String?
        private var table: ChatMarkdownTable?
        private weak var layoutStore: ChatTextLayoutStore?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            tableView.setAccessibilityElement(false)
            documentView = tableView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            layoutID: String,
            table: ChatMarkdownTable,
            layoutStore: ChatTextLayoutStore
        ) {
            guard self.layoutID != layoutID || self.table != table
                || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.table = table
            self.layoutStore = layoutStore
            needsLayout = true
        }

        override func layout() {
            if let layoutID, let table, let layoutStore {
                let layout = layoutStore.tableLayout(id: layoutID, table: table)
                if tableView.tableLayout !== layout {
                    tableView.tableLayout = layout
                    documentSize = layout.size
                }
            }
            super.layout()
        }
    }

    // MARK: - Horizontal container

    /// A horizontal-only scroll container for a document of known size that
    /// lets vertical wheel gestures continue through the enclosing chat
    /// timeline.
    class ChatMacHorizontalDocumentScrollView: NSScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        /// The document's natural size; the document is at least as wide as
        /// the clip view so short content still fills the row.
        var documentSize: NSSize = .zero {
            didSet {
                if documentSize != oldValue { needsLayout = true }
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            drawsBackground = false
            borderType = .noBorder
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            horizontalScrollElasticity = .automatic
            verticalScrollElasticity = .none
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            guard let documentView else { return }
            let size = NSSize(
                width: max(contentSize.width, documentSize.width),
                height: documentSize.height
            )
            if documentView.frame.size != size {
                documentView.setFrameSize(size)
            }
        }

        /// AppKit sends one diagonal trackpad event to the deepest scroll
        /// view. Split its axes at that boundary: this view owns x and the
        /// transcript owns y. A dominance heuristic makes the route flip
        /// during a gesture and drops the smaller axis, which is the
        /// stuttering/"stuck over code" behavior this wrapper prevents.
        override func scrollWheel(with event: NSEvent) {
            let hasHorizontalDelta = abs(event.scrollingDeltaX) > 0
            let hasVerticalDelta = abs(event.scrollingDeltaY) > 0

            if hasHorizontalDelta {
                super.scrollWheel(with: event)
            }
            if hasVerticalDelta, let enclosingVerticalScrollView {
                enclosingVerticalScrollView.scrollWheel(with: event)
            }
            if !hasHorizontalDelta, !hasVerticalDelta {
                super.scrollWheel(with: event)
            }
        }

        private var enclosingVerticalScrollView: NSScrollView? {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                candidate = view.superview
            }
            return nil
        }
    }
#endif
