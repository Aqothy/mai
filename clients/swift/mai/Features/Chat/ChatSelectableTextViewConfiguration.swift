#if os(macOS)
    import AppKit

    enum ChatSelectableTextViewConfiguration {
        static func makeTextView() -> NSTextView {
            // NSTextView owns its selection/link cursor tracking. Adding an
            // I-beam cursor rect here duplicates that work on every scroll.
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
            // Row height comes from a complete prepared layout. A contiguous
            // display graph prevents recycled rows from showing an empty tail
            // after AppKit jumps directly into their lower half.
            view.layoutManager?.allowsNonContiguousLayout = false
            view.linkTextAttributes = [
                .foregroundColor: NSColor.labelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            return view
        }
    }
#else
    import UIKit

    enum ChatSelectableTextViewConfiguration {
        static func makeTextView() -> UITextView {
            let view = UITextView(usingTextLayoutManager: false)
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
            return view
        }
    }
#endif
