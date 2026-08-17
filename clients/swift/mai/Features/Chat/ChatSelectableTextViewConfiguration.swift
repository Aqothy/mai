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
}
