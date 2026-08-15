#if os(iOS)
    import SwiftUI
    import UIKit

    enum ChatSelectableTextViewConfiguration {
        static func makeTextView() -> UITextView {
            let view = UITextView(usingTextLayoutManager: false)
            apply(to: view)
            return view
        }

        static func apply(to view: UITextView) {
            view.isScrollEnabled = false
            view.isEditable = false
            view.isSelectable = true
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.contentInset = .zero
            view.adjustsFontForContentSizeCategory = false
            view.linkTextAttributes = [
                .foregroundColor: UIColor.label,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            view.accessibilityTraits.insert(.staticText)
        }

        static func update(
            _ view: UITextView,
            attributedString: NSAttributedString
        ) {
            guard !view.attributedText.isEqual(to: attributedString) else {
                return
            }
            let selection = view.selectedRange
            view.attributedText = attributedString
            if NSMaxRange(selection) <= attributedString.length {
                view.selectedRange = selection
            }
        }
    }

    /// Selectable code content for a horizontal SwiftUI ScrollView.
    struct ChatSelectableRichText: UIViewRepresentable {
        let attributedString: NSAttributedString
        let size: CGSize

        init(attributedString: NSAttributedString) {
            self.attributedString = attributedString
            self.size = Self.measure(attributedString)
        }

        func makeUIView(context: Context) -> UITextView {
            ChatSelectableTextViewConfiguration.makeTextView()
        }

        func updateUIView(_ view: UITextView, context: Context) {
            ChatSelectableTextViewConfiguration.update(
                view,
                attributedString: attributedString
            )
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: UITextView,
            context: Context
        ) -> CGSize? {
            size
        }

        private static func measure(
            _ attributedString: NSAttributedString
        ) -> CGSize {
            let storage = NSTextStorage(attributedString: attributedString)
            let manager = NSLayoutManager()
            let container = NSTextContainer(
                size: CGSize(
                    width: 1_000_000,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)

            let usedRect = manager.usedRect(for: container)
            return CGSize(
                width: ceil(max(1, usedRect.maxX)),
                height: ceil(max(1, usedRect.maxY))
            )
        }
    }
#elseif os(macOS)
    import AppKit
    import SwiftUI

    enum ChatMacSelectableTextViewConfiguration {
        static func makeTextView() -> NSTextView {
            let view = NSTextView(usingTextLayoutManager: false)
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = true
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.isVerticallyResizable = false
            view.isHorizontallyResizable = false
            view.allowsUndo = false
            view.textContainer?.lineFragmentPadding = 0
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.heightTracksTextView = false
            // List row height is computed from a complete TextKit layout.
            // Keeping the display graph non-contiguous can leave its final
            // laid-out glyph hundreds of points above that measured height
            // after a row is recycled, producing a visible empty tail.
            view.layoutManager?.allowsNonContiguousLayout = false
            view.linkTextAttributes = [
                .foregroundColor: NSColor.labelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            return view
        }
    }

    /// Selectable, premeasured code content for a horizontal SwiftUI ScrollView.
    /// Measurement is cached by this value, while the visible NSTextView keeps
    /// its own TextKit graph so recycling can never detach another visible row.
    struct ChatSelectableRichText: NSViewRepresentable {
        let attributedString: NSAttributedString
        private let layout: Layout

        init(attributedString: NSAttributedString) {
            self.attributedString = attributedString
            self.layout = Layout(attributedString: attributedString)
        }

        func makeNSView(context: Context) -> NSTextView {
            ChatMacSelectableTextViewConfiguration.makeTextView()
        }

        func updateNSView(
            _ nsView: NSTextView,
            context: Context
        ) {
            nsView.textContainer?.containerSize = NSSize(
                width: max(1, layout.size.width),
                height: .greatestFiniteMagnitude
            )
            guard nsView.textStorage?.isEqual(to: attributedString) != true else {
                return
            }
            let selection = nsView.selectedRange()
            nsView.textStorage?.setAttributedString(attributedString)
            if NSMaxRange(selection) <= attributedString.length {
                nsView.setSelectedRange(selection)
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: NSTextView,
            context: Context
        ) -> CGSize? {
            layout.size
        }

        fileprivate final class Layout {
            let size: CGSize

            init(attributedString: NSAttributedString) {
                let storage = NSTextStorage(attributedString: attributedString)
                let manager = NSLayoutManager()
                let container = NSTextContainer(
                    containerSize: NSSize(
                        width: 1_000_000,
                        height: CGFloat.greatestFiniteMagnitude
                    )
                )
                container.lineFragmentPadding = 0
                container.widthTracksTextView = false
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                manager.ensureLayout(for: container)

                let usedRect = manager.usedRect(for: container)
                self.size = CGSize(
                    width: ceil(max(1, usedRect.maxX)),
                    height: ceil(max(1, usedRect.maxY))
                )
            }
        }
    }
#endif
