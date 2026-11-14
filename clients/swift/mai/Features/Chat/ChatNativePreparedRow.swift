#if os(macOS)
    import AppKit

    /// Native presentation for prepared assistant prose, code and tables.
    /// Unsupported rows retain the SwiftUI renderer. A row's geometry comes
    /// from the same prepared layout as its visible native body.
    final class ChatNativePreparedRow: NSView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private var descriptor: Descriptor?
        private var bodyView: NSView?
        // Each bounded row host lazily retains one body of each supported kind.
        // Switching row kinds replaces content without rebuilding NSTextViews.
        private lazy var proseView = ChatSelectableTextHostView()
        private lazy var codeView = ChatMacCodeBlockHostView(frame: .zero)
        private lazy var tableView = ChatMacTableHostView(frame: .zero)
        /// The code block's rounded surface. A layer draws it: a `draw(_:)`
        /// override would give every row, prose included, a bitmap of its
        /// own size.
        private let codeBackground = NSView()
        private let language = NSTextField(labelWithString: "")
        private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
        private var copyText = ""
        private var feedbackTask: Task<Void, Never>?
        private var contentWidth: CGFloat = 0
        private var theme = ChatCodeHighlightTheme.light
        /// The store the body's layouts come from. A new one (a Dynamic Type
        /// change) holds layouts at other sizes, and the rows' heights
        /// already come from it.
        private weak var store: ChatTextLayoutStore?
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityRole(.group)
            codeBackground.wantsLayer = true
            codeBackground.layer?.cornerRadius = ChatRichBlockStyle.codeCornerRadius
            codeBackground.layer?.cornerCurve = .continuous
            codeBackground.layer?.borderWidth = 1
            codeBackground.isHidden = true
            language.font = NSFont.preferredFont(forTextStyle: .callout)
            copyButton.isBordered = false
            copyButton.imagePosition = .imageOnly
            copyButton.image = NSImage(
                systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
            copyButton.target = self
            copyButton.action = #selector(copyContent)
            addSubview(codeBackground)
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
            if self.descriptor == descriptor, self.theme == theme,
                self.store === store
            {
                needsLayout = true
                return
            }
            feedbackTask?.cancel()
            feedbackTask = nil
            self.descriptor = descriptor
            self.theme = theme
            self.store = store
            copyButton.image = NSImage(
                systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
            language.isHidden = true
            copyButton.isHidden = true
            codeBackground.isHidden = true
            setAccessibilityElement(false)
            switch descriptor.content {
            case .prose(let text):
                let prose = proseView
                setBody(prose)
                prose.annotationContext = annotationContext
                prose.update(layoutID: descriptor.id, content: text, layoutStore: store)
            case .code(let code):
                let codeView = self.codeView
                setBody(codeView)
                (codeView.documentView as? ChatAnnotationTextView)?.annotationContext = annotationContext
                codeView.contentView.scroll(to: .zero)
                codeView.update(
                    layoutID: descriptor.id, block: code, theme: theme, layoutStore: store)
                applyCodeBackgroundColors()
                codeBackground.isHidden = false
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
        }

        private func setBody(_ view: NSView) {
            guard bodyView !== view else { return }
            (bodyView as? ChatMacCodeBlockHostView)?.dismantle()
            (bodyView as? ChatSelectableTextHostView)?.dismantle()
            bodyView?.removeFromSuperview()
            bodyView = view
            addSubview(view)
            subviews = [codeBackground, language, copyButton, view]
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
            case .prose:
                bodyView?.frame = rect
            case .code:
                let headerHeight = ChatRichBlockStyle.codeHeaderHeight
                codeBackground.frame = rect
                language.frame = NSRect(
                    x: rect.minX + ChatRichBlockStyle.codeHeaderHorizontalInset,
                    y: rect.minY + ChatRichBlockStyle.codeHeaderTopInset,
                    width: max(0, rect.width - 64),
                    height: ChatRichBlockStyle.codeHeaderContentHeight)
                copyButton.frame = NSRect(
                    x: max(0, rect.maxX - 40), y: rect.minY + 10, width: 24, height: 24)
                bodyView?.frame = NSRect(
                    x: rect.minX, y: rect.minY + headerHeight, width: rect.width,
                    height: max(0, rect.height - headerHeight))
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

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyCodeBackgroundColors()
        }

        /// Layer colors are resolved values; they do not follow the
        /// appearance on their own.
        private func applyCodeBackgroundColors() {
            guard let layer = codeBackground.layer else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor =
                    NSColor.labelColor.withAlphaComponent(
                        CGFloat(ChatRichBlockStyle.codeBackgroundOpacity(isDark: theme == .dark))
                    ).cgColor
                layer.borderColor =
                    NSColor.labelColor.withAlphaComponent(
                        CGFloat(ChatRichBlockStyle.codeBorderOpacity)
                    ).cgColor
            }
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
