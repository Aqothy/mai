#if os(iOS)
    import UIKit

    /// The transcript's text as UIKit's text system sees it (PLAN 5): a
    /// read-only `UITextInput` over the controller's selection, so
    /// `UITextInteraction(for: .nonEditable)` brings the system's long-press
    /// selection, handles, loupe, highlight and edit menu. Document-sized
    /// inside the scroll view, so its coordinates are the document's.
    ///
    /// The selectable rows read as one text, joined by newlines; positions
    /// are rows and offsets (`TextPosition`), walked row by row.
    final class TranscriptTextInputView: UIView, UITextInput {
        weak var controller: TranscriptController?
        /// The column's left edge in the document.
        var columnX: () -> CGFloat = { 0 }
        /// How far a wide block's body is scrolled, by row ID.
        var scrollX: (String) -> CGFloat = { _ in 0 }
        /// Starts a Comment on the selection (PLAN Q4).
        var onComment: ((String, String?, String?) -> Void)?

        /// UIKit is setting the selection: it needs no word back about it.
        private(set) var isApplyingSystemSelection = false
        /// VoiceOver's elements by row ID (see the accessibility extension).
        var rowElements: [String: TranscriptAccessibilityRow] = [:]

        weak var inputDelegate: (any UITextInputDelegate)?
        lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

        override var canBecomeFirstResponder: Bool { true }
        var isEditable: Bool { false }

        /// Tells UIKit the selection's rects moved (rows laid out again,
        /// scrolled code, a new selection), so it redraws its highlight.
        func selectionGeometryDidChange() {
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.selectionDidChange(self)
        }

        // MARK: Positions

        private func position(_ position: UITextPosition) -> TextPosition? {
            (position as? TranscriptTextPosition)?.position
        }

        private var emptyPosition: TextPosition { TextPosition(rowID: "", offset: 0) }

        var beginningOfDocument: UITextPosition {
            TranscriptTextPosition(controller?.firstTextPosition ?? emptyPosition)
        }

        var endOfDocument: UITextPosition {
            TranscriptTextPosition(controller?.lastTextPosition ?? emptyPosition)
        }

        func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let from = position(fromPosition), let to = position(toPosition) else { return nil }
            return range(from, to)
        }

        /// A range of two positions in either order.
        private func range(_ a: TextPosition, _ b: TextPosition) -> TranscriptTextRange {
            controller?.isBefore(b, a) == true ? TranscriptTextRange(from: b, to: a) : TranscriptTextRange(from: a, to: b)
        }

        func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let start = self.position(position),
                let moved = controller?.position(from: start, offset: offset)
            else { return nil }
            return TranscriptTextPosition(moved)
        }

        func position(
            from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
        ) -> UITextPosition? {
            switch direction {
            case .left, .up: self.position(from: position, offset: -offset)
            default: self.position(from: position, offset: offset)
            }
        }

        func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            guard let a = self.position(position), let b = self.position(other), a != b,
                let before = controller?.isBefore(a, b)
            else { return .orderedSame }
            return before ? .orderedAscending : .orderedDescending
        }

        func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            guard let a = position(from), let b = position(toPosition) else { return 0 }
            return controller?.offset(from: a, to: b) ?? 0
        }

        func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
            switch direction {
            case .left, .up: range.start
            default: range.end
            }
        }

        func characterRange(
            byExtending position: UITextPosition, in direction: UITextLayoutDirection
        ) -> UITextRange? {
            guard let start = self.position(position), let controller else { return nil }
            let target: TextPosition? =
                switch direction {
                case .left: controller.paragraphRange(around: start)?.anchor
                case .right: controller.paragraphRange(around: start)?.focus
                case .up: controller.firstTextPosition
                case .down: controller.lastTextPosition
                @unknown default: nil
                }
            return target.map { range(start, $0) }
        }

        // MARK: Text

        func text(in range: UITextRange) -> String? {
            guard let range = range as? TranscriptTextRange else { return nil }
            return controller?.text(from: range.from.position, to: range.to.position)
        }

        var selectedTextRange: UITextRange? {
            get {
                guard let selection = controller?.selection else { return nil }
                return range(selection.anchor, selection.focus)
            }
            set {
                isApplyingSystemSelection = true
                defer { isApplyingSystemSelection = false }
                guard let range = newValue as? TranscriptTextRange, !range.isEmpty else {
                    controller?.setSelection(nil)
                    return
                }
                controller?.setSelection(TranscriptSelection(anchor: range.from.position, focus: range.to.position))
            }
        }

        var hasText: Bool { controller?.firstTextPosition != nil }

        // MARK: Geometry

        func firstRect(for range: UITextRange) -> CGRect {
            selectionRects(for: range).first?.rect ?? .null
        }

        func caretRect(for position: UITextPosition) -> CGRect {
            guard let position = self.position(position) else { return .null }
            return controller?.caretRect(for: position, columnX: columnX(), scrollX: scrollX) ?? .null
        }

        func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            guard let range = range as? TranscriptTextRange, let controller else { return [] }
            let rects = controller.selectionRects(
                from: range.from.position, to: range.to.position, columnX: columnX(), scrollX: scrollX)
            return rects.enumerated().map { index, rect in
                TranscriptSelectionRect(rect, isStart: index == 0, isEnd: index == rects.count - 1)
            }
        }

        func closestPosition(to point: CGPoint) -> UITextPosition? {
            controller?.textPosition(atDocumentPoint: point, columnX: columnX(), scrollX: scrollX)
                .map(TranscriptTextPosition.init)
        }

        func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
            guard let closest = closestPosition(to: point) else { return nil }
            if compare(closest, to: range.start) == .orderedAscending { return range.start }
            if compare(closest, to: range.end) == .orderedDescending { return range.end }
            return closest
        }

        func characterRange(at point: CGPoint) -> UITextRange? {
            guard let start = controller?.textPosition(atDocumentPoint: point, columnX: columnX(), scrollX: scrollX),
                let cluster = controller?.characterRange(around: start)
            else { return nil }
            return TranscriptTextRange(from: cluster.anchor, to: cluster.focus)
        }

        // MARK: Edit menu

        override func copy(_ sender: Any?) {
            let text = controller?.selectedText() ?? ""
            guard !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }

        override func selectAll(_ sender: Any?) {
            controller?.selectAll()
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(copy(_:)): controller?.hasValidSelection == true
            case #selector(selectAll(_:)): hasText
            default: false
            }
        }

        func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onComment else { return UIMenu(children: suggestedActions) }
            let comment = UIAction(title: "Comment…", image: UIImage(systemName: "text.bubble")) {
                [weak self] _ in
                guard let controller = self?.controller else { return }
                let quote = controller.selectedText()
                guard !quote.isEmpty else { return }
                let target = controller.selectionCommentTarget()
                onComment(quote, target.messageID, target.role)
            }
            return UIMenu(children: suggestedActions + [comment])
        }

        // MARK: Editing (read-only: nothing changes)

        var markedTextRange: UITextRange? { nil }
        var markedTextStyle: [NSAttributedString.Key: Any]? {
            get { nil }
            set {}
        }

        func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}
        func unmarkText() {}
        func replace(_ range: UITextRange, withText text: String) {}
        func insertText(_ text: String) {}
        func deleteBackward() {}

        func baseWritingDirection(
            for position: UITextPosition, in direction: UITextStorageDirection
        ) -> NSWritingDirection { .natural }

        func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    }
#endif
