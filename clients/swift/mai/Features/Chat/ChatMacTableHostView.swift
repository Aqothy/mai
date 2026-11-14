#if os(macOS)
    import AppKit

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
#endif
