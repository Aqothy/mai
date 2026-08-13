#if os(iOS)
    import SwiftUI
    import UIKit

    enum ChatSelectableTextViewConfiguration {
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
            let view = UITextView(usingTextLayoutManager: false)
            ChatSelectableTextViewConfiguration.apply(to: view)
            return view
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

#endif
