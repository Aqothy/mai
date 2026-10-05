#if os(macOS)
    import AppKit

    /// Native presentation for prepared assistant prose, code and tables.
    /// Unsupported rows retain the existing SwiftUI renderer. Prose and table
    /// geometry uses the same prepared layouts as their visible native bodies.
    final class ChatNativePreparedRow: NSView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        enum Content: Equatable {
            case prose(String)
            case resolvedProse(ChatMarkdownProseRun)
            case code(ChatMarkdownCodeBlock)
            case table(ChatMarkdownTable)
        }
        struct Descriptor: Equatable {
            let id: String
            let content: Content
            let top: CGFloat
            let bottom: CGFloat
        }

        static func descriptor(for row: ChatTimelineRenderRow) -> Descriptor? {
            switch row {
            case .prose(let segment):
                guard segment.role == "assistant", segment.attachments?.isEmpty != false, segment.annotations?.isEmpty != false else {
                    return nil
                }
                return Descriptor(
                    id: segment.rowID, content: .prose(segment.source),
                    top: segment.isFirst ? ChatTimelineMetrics.rowVerticalInset : 0,
                    bottom: segment.isLast
                        ? ChatTimelineMetrics.rowVerticalInset
                        : ChatTimelineMetrics.interSegmentSpacing)
            case .resolvedMarkdown(let block):
                guard block.attachments?.isEmpty != false else { return nil }
                let content: Content
                switch block.content {
                case .proseRun(let prose): content = .resolvedProse(prose)
                case .code(let code): content = .code(code)
                case .table(let table): content = .table(table)
                case .prose: return nil
                }
                return Descriptor(
                    id: block.rowID, content: content,
                    top: block.isFirst
                        ? ChatTimelineMetrics.rowVerticalInset
                        : ChatMarkdownProseStyle.blockSpacing,
                    bottom: block.isLast ? ChatTimelineMetrics.rowVerticalInset : 0)
            case .richMarkdown(let segment):
                guard segment.role == "assistant", segment.attachments?.isEmpty != false, segment.annotations?.isEmpty != false,
                    let plan = ChatMarkdownRenderCache.shared.cachedPlan(
                        messageID: segment.rowID, source: segment.source),
                    plan.blocks.count == 1, let block = plan.blocks.first
                else { return nil }
                let content: Content
                switch block {
                case .prose: return nil
                case .code(let code): content = .code(code)
                case .table(let table): content = .table(table)
                }
                return Descriptor(
                    id: "\(segment.rowID)-block-0", content: content,
                    top: segment.isFirst ? ChatTimelineMetrics.rowVerticalInset : 0,
                    bottom: segment.isLast
                        ? ChatTimelineMetrics.rowVerticalInset
                        : ChatTimelineMetrics.interSegmentSpacing)
            case .standard: return nil
            }
        }

        /// Text and table layouts already contain exact geometry. Code headers
        /// and interactive rows continue to use the existing SwiftUI measurement.
        static func preparedHeight(
            for descriptor: Descriptor, width: CGFloat, store: ChatTextLayoutStore
        ) -> CGFloat? {
            let bodyHeight: CGFloat
            switch descriptor.content {
            case .prose(let source):
                bodyHeight = store.layout(
                    id: descriptor.id, source: source, width: width).height
            case .resolvedProse(let prose):
                bodyHeight = store.resolvedLayout(
                    id: descriptor.id, prose: prose, width: width).height
            case .table(let table):
                bodyHeight = store.tableLayout(id: descriptor.id, table: table).size.height
                    + ChatRichBlockStyle.tableToolbarHeight
            case .code:
                return nil
            }
            return ceil(bodyHeight + descriptor.top + descriptor.bottom)
        }

        private var descriptor: Descriptor?
        private var bodyView: NSView?
        // Each bounded row host lazily retains one body of each supported kind.
        // Switching row kinds replaces content without rebuilding NSTextViews.
        private lazy var proseView = ChatSelectableTextHostView()
        private lazy var codeView = ChatMacCodeBlockHostView(frame: .zero)
        private lazy var tableView = ChatMacTableHostView(frame: .zero)
        private let language = NSTextField(labelWithString: "")
        private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
        private var copyText = ""
        private var feedbackTask: Task<Void, Never>?
        private var contentWidth: CGFloat = 0
        private var codeHeight: CGFloat = 0
        private var theme = ChatCodeHighlightTheme.light
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityRole(.group)
            language.font = NSFont.preferredFont(forTextStyle: .callout)
            copyButton.isBordered = false
            copyButton.imagePosition = .imageOnly
            copyButton.image = NSImage(
                systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
            copyButton.target = self
            copyButton.action = #selector(copyContent)
            addSubview(language)
            addSubview(copyButton)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(
            _ descriptor: Descriptor, width: CGFloat, store: ChatTextLayoutStore,
            theme: ChatCodeHighlightTheme,
            annotationContext: ChatAnnotationContext? = nil
        ) {
            (bodyView as? ChatSelectableTextHostView)?.annotationContext = annotationContext
            if let code = bodyView as? ChatMacCodeBlockHostView {
                (code.documentView as? ChatAnnotationTextView)?.annotationContext = annotationContext
            }
            contentWidth = width
            if self.descriptor == descriptor, self.theme == theme {
                needsLayout = true
                return
            }
            feedbackTask?.cancel()
            feedbackTask = nil
            self.descriptor = descriptor
            contentWidth = width
            self.theme = theme
            copyButton.image = NSImage(
                systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
            language.isHidden = true
            copyButton.isHidden = true
            setAccessibilityElement(false)
            switch descriptor.content {
            case .prose(let source):
                let prose = proseView
                setBody(prose)
                prose.annotationContext = annotationContext
                prose.update(layoutID: descriptor.id, source: source, layoutStore: store)
            case .resolvedProse(let text):
                let prose = proseView
                setBody(prose)
                prose.annotationContext = annotationContext
                prose.update(layoutID: descriptor.id, resolvedProse: text, layoutStore: store)
            case .code(let code):
                let codeView = self.codeView
                setBody(codeView)
                (codeView.documentView as? ChatAnnotationTextView)?.annotationContext = annotationContext
                codeView.contentView.scroll(to: .zero)
                codeView.update(
                    layoutID: descriptor.id, block: code, theme: theme, layoutStore: store)
                codeHeight =
                    store.codeLayout(id: descriptor.id, block: code, theme: theme).layout.height
                    + ChatMacCodeStyle.bottomInset
                language.stringValue = code.displayLanguage
                language.isHidden = false
                copyText = code.code
                copyButton.isHidden = false
                copyButton.setAccessibilityLabel("Copy code")
                copyButton.setAccessibilityHelp("Copies this code block to the Clipboard")
                setAccessibilityElement(true)
                setAccessibilityLabel("\(code.displayLanguage) code block")
            case .table(let table):
                let tableView = self.tableView
                setBody(tableView)
                tableView.contentView.scroll(to: .zero)
                tableView.update(layoutID: descriptor.id, table: table, layoutStore: store)
                copyText = table.tabSeparatedText
                copyButton.isHidden = false
                copyButton.setAccessibilityLabel("Copy table")
                copyButton.setAccessibilityHelp("Copies this table to the Clipboard")
                setAccessibilityElement(true)
                setAccessibilityLabel("Markdown table")
                setAccessibilityValue(table.tabSeparatedText)
            }
            needsLayout = true
            needsDisplay = true
        }

        private func setBody(_ view: NSView) {
            guard bodyView !== view else { return }
            (bodyView as? ChatMacCodeBlockHostView)?.dismantle()
            (bodyView as? ChatSelectableTextHostView)?.dismantle()
            bodyView?.removeFromSuperview()
            bodyView = view
            addSubview(view)
            subviews = [language, copyButton, view]
            setAccessibilityLabel(nil)
            setAccessibilityValue(nil)
        }

        override func layout() {
            super.layout()
            guard let descriptor else { return }
            let width = min(contentWidth, bounds.width)
            let rect = NSRect(
                x: (bounds.width - width) / 2, y: descriptor.top, width: width,
                height: max(0, bounds.height - descriptor.top - descriptor.bottom))
            switch descriptor.content {
            case .prose, .resolvedProse:
                bodyView?.frame = rect
            case .code:
                let headerHeight = max(0, rect.height - codeHeight)
                language.frame = NSRect(
                    x: rect.minX + ChatRichBlockStyle.codeHeaderHorizontalInset,
                    y: rect.minY + ChatRichBlockStyle.codeHeaderTopInset,
                    width: max(0, rect.width - 64),
                    height: max(
                        0,
                        headerHeight - ChatRichBlockStyle.codeHeaderTopInset
                            - ChatRichBlockStyle.codeHeaderBottomInset))
                copyButton.frame = NSRect(
                    x: max(0, rect.maxX - 40), y: rect.minY + 10, width: 24, height: 24)
                bodyView?.frame = NSRect(
                    x: rect.minX, y: rect.minY + headerHeight, width: rect.width, height: codeHeight
                )
            case .table:
                copyButton.frame = NSRect(
                    x: max(0, rect.maxX - ChatRichBlockStyle.tableToolbarHeight), y: rect.minY,
                    width: ChatRichBlockStyle.tableToolbarHeight,
                    height: ChatRichBlockStyle.tableToolbarHeight)
                bodyView?.frame = NSRect(
                    x: rect.minX, y: rect.minY + ChatRichBlockStyle.tableToolbarHeight,
                    width: rect.width,
                    height: max(0, rect.height - ChatRichBlockStyle.tableToolbarHeight))
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let descriptor, case .code = descriptor.content else { return }
            let width = min(contentWidth, bounds.width)
            let rect = NSRect(
                x: (bounds.width - width) / 2, y: descriptor.top, width: width,
                height: max(0, bounds.height - descriptor.top - descriptor.bottom))
            let path = NSBezierPath(
                roundedRect: rect, xRadius: ChatRichBlockStyle.codeCornerRadius,
                yRadius: ChatRichBlockStyle.codeCornerRadius)
            NSColor.labelColor.withAlphaComponent(
                CGFloat(ChatRichBlockStyle.codeBackgroundOpacity(isDark: theme == .dark))
            ).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(CGFloat(ChatRichBlockStyle.codeBorderOpacity))
                .setStroke()
            path.stroke()
        }

        @objc private func copyContent() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyText, forType: .string)
            copyButton.image = NSImage(
                systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            copyButton.setAccessibilityLabel("Copied")
            feedbackTask?.cancel()
            feedbackTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard let self else { return }
                self.copyButton.image = NSImage(
                    systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
                if case .table = self.descriptor?.content {
                    self.copyButton.setAccessibilityLabel("Copy table")
                } else {
                    self.copyButton.setAccessibilityLabel("Copy code")
                }
            }
        }
    }
#endif
