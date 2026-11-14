#if os(iOS)
    import UIKit

    /// Native presentation for prepared assistant prose, code and tables.
    /// Unsupported rows retain the SwiftUI renderer. A row's geometry comes
    /// from the same prepared layout as its visible native body.
    final class ChatNativePreparedRow: UIView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        /// The touch target of a copy button, whatever its glyph's size.
        private static let copyButtonSize: CGFloat = 44

        private var descriptor: Descriptor?
        private var bodyView: UIView?
        // Each bounded row host lazily retains one body of each supported kind.
        // Switching row kinds replaces content without rebuilding text views.
        private lazy var proseView = ChatSelectableTextHostView()
        private lazy var codeView = ChatCodeBlockHostView()
        private lazy var tableView = ChatTableHostView()
        /// The code block's rounded surface. A layer draws it without the
        /// row-sized bitmap a `draw(_:)` override would allocate.
        private let codeBackground = UIView()
        private let language = UILabel()
        private let copyButton = UIButton(type: .system)
        private var copyText = ""
        private var feedbackTask: Task<Void, Never>?
        private var contentWidth: CGFloat = 0
        private var theme = ChatCodeHighlightTheme.light
        /// The store the body's layouts come from. A new one (a Dynamic Type
        /// change) holds layouts at other sizes, and the rows' heights
        /// already come from it.
        private weak var store: ChatTextLayoutStore?

        override init(frame: CGRect) {
            super.init(frame: frame)
            codeBackground.isUserInteractionEnabled = false
            codeBackground.layer.cornerRadius = ChatRichBlockStyle.codeCornerRadius
            codeBackground.layer.cornerCurve = .continuous
            codeBackground.layer.borderWidth = 1
            codeBackground.isHidden = true
            language.font = .preferredFont(forTextStyle: .callout)
            language.adjustsFontForContentSizeCategory = true
            language.textColor = .label
            language.isHidden = true
            copyButton.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(textStyle: .body), forImageIn: .normal)
            copyButton.addTarget(self, action: #selector(copyContent), for: .touchUpInside)
            copyButton.isHidden = true
            addSubview(codeBackground)
            addSubview(language)
            addSubview(copyButton)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (row: ChatNativePreparedRow, _: UITraitCollection) in
                row.applyCodeBackgroundColors()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            _ descriptor: Descriptor, width: CGFloat, store: ChatTextLayoutStore,
            theme: ChatCodeHighlightTheme,
            annotationContext: ChatAnnotationContext? = nil
        ) {
            (bodyView as? ChatSelectableTextHostView)?.annotationContext = annotationContext
            (bodyView as? ChatCodeBlockHostView)?.annotationContext = annotationContext
            if contentWidth != width {
                contentWidth = width
                setNeedsLayout()
            }
            guard
                self.descriptor != descriptor || self.theme != theme
                    || self.store !== store
            else { return }
            feedbackTask?.cancel()
            feedbackTask = nil
            self.descriptor = descriptor
            self.theme = theme
            self.store = store
            showCopyImage(copied: false)
            language.isHidden = true
            copyButton.isHidden = true
            codeBackground.isHidden = true
            switch descriptor.content {
            case .prose(let text):
                let prose = proseView
                setBody(prose)
                prose.annotationContext = annotationContext
                prose.update(layoutID: descriptor.id, content: text, layoutStore: store)
                accessibilityElements = [prose]
            case .code(let code):
                let codeView = self.codeView
                setBody(codeView)
                codeView.annotationContext = annotationContext
                codeView.contentOffset = .zero
                codeView.update(
                    layoutID: descriptor.id, block: code, theme: theme, layoutStore: store)
                applyCodeBackgroundColors()
                codeBackground.isHidden = false
                language.text = code.displayLanguage
                language.accessibilityLabel = "\(code.displayLanguage) code block"
                language.isHidden = false
                copyText = code.code
                copyButton.tintColor = .label
                copyButton.isHidden = false
                copyButton.accessibilityLabel = copyLabel
                copyButton.accessibilityHint = "Copies this code block to the Clipboard"
                // VoiceOver reads the language, then the copy button, then the code.
                accessibilityElements = [language, copyButton, codeView]
            case .table(let table):
                let tableView = self.tableView
                setBody(tableView)
                tableView.contentOffset = .zero
                tableView.update(layoutID: descriptor.id, table: table, layoutStore: store)
                copyText = table.tabSeparatedText
                copyButton.tintColor = .secondaryLabel
                copyButton.isHidden = false
                copyButton.accessibilityLabel = copyLabel
                copyButton.accessibilityHint = "Copies the table to the Clipboard"
                accessibilityElements = [copyButton, tableView]
            }
            setNeedsLayout()
        }

        private func setBody(_ view: UIView) {
            guard bodyView !== view else { return }
            (bodyView as? ChatCodeBlockHostView)?.dismantle()
            (bodyView as? ChatSelectableTextHostView)?.dismantle()
            bodyView?.removeFromSuperview()
            bodyView = view
            addSubview(view)
        }

        /// The row spans the transcript; its content is the centered column
        /// between the row's vertical insets.
        private var contentRect: CGRect {
            guard let descriptor else { return .zero }
            let width = min(contentWidth, bounds.width)
            return CGRect(
                x: (bounds.width - width) / 2, y: descriptor.top, width: width,
                height: max(0, bounds.height - descriptor.top - descriptor.bottom))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let descriptor else { return }
            let rect = contentRect
            switch descriptor.content {
            case .prose:
                bodyView?.frame = rect
            case .code:
                let headerHeight = ChatRichBlockStyle.codeHeaderHeight
                let titleHeight = ChatRichBlockStyle.codeHeaderContentHeight
                let titleMinY = rect.minY + ChatRichBlockStyle.codeHeaderTopInset
                codeBackground.frame = rect
                language.frame = CGRect(
                    x: rect.minX + ChatRichBlockStyle.codeHeaderHorizontalInset,
                    y: titleMinY,
                    width: max(
                        0,
                        rect.width - 2 * ChatRichBlockStyle.codeHeaderHorizontalInset
                            - Self.copyButtonSize),
                    height: titleHeight)
                // The glyph sits at the header's trailing inset; the button
                // around it is a full-size touch target.
                let glyphWidth = copyButton.intrinsicContentSize.width
                copyButton.frame = CGRect(
                    x: rect.maxX - ChatRichBlockStyle.codeHeaderHorizontalInset
                        - (Self.copyButtonSize + glyphWidth) / 2,
                    y: titleMinY + (titleHeight - Self.copyButtonSize) / 2,
                    width: Self.copyButtonSize, height: Self.copyButtonSize)
                bodyView?.frame = CGRect(
                    x: rect.minX, y: rect.minY + headerHeight, width: rect.width,
                    height: max(0, rect.height - headerHeight))
            case .table:
                copyButton.frame = CGRect(
                    x: rect.maxX - ChatRichBlockStyle.tableToolbarHeight, y: rect.minY,
                    width: ChatRichBlockStyle.tableToolbarHeight,
                    height: ChatRichBlockStyle.tableToolbarHeight)
                bodyView?.frame = CGRect(
                    x: rect.minX, y: rect.minY + ChatRichBlockStyle.tableToolbarHeight,
                    width: rect.width,
                    height: max(0, rect.height - ChatRichBlockStyle.tableToolbarHeight))
            }
        }

        /// Layer colors are resolved values; they do not follow the
        /// appearance on their own.
        private func applyCodeBackgroundColors() {
            codeBackground.backgroundColor = UIColor.label.withAlphaComponent(
                ChatRichBlockStyle.codeBackgroundOpacity(isDark: theme == .dark))
            codeBackground.layer.borderColor =
                UIColor.label.withAlphaComponent(ChatRichBlockStyle.codeBorderOpacity)
                .resolvedColor(with: traitCollection).cgColor
        }

        private var copyLabel: String {
            if case .table = descriptor?.content { "Copy table" } else { "Copy code" }
        }

        private func showCopyImage(copied: Bool) {
            copyButton.setImage(
                UIImage(systemName: copied ? "checkmark" : "square.on.square"), for: .normal)
        }

        @objc private func copyContent() {
            UIPasteboard.general.string = copyText
            showCopyImage(copied: true)
            copyButton.accessibilityLabel = "Copied"
            feedbackTask?.cancel()
            feedbackTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard let self else { return }
                self.showCopyImage(copied: false)
                self.copyButton.accessibilityLabel = self.copyLabel
            }
        }
    }
#endif
