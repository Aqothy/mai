#if os(iOS)
    import UIKit

    /// Offers "Comment…" on a text selection in the transcript.
    final class ChatTextEditMenuDelegate: NSObject, UITextViewDelegate {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var annotationContext: ChatAnnotationContext?

        /// The single-range callback is the one available on every supported
        /// iOS version; iOS 26 calls it with the selection's union range when
        /// the multi-range variant is not implemented.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let annotationContext, range.length > 0,
                NSMaxRange(range) <= textView.attributedText.length
            else {
                return UIMenu(children: suggestedActions)
            }
            let quote = textView.attributedText.attributedSubstring(from: range).string
            let comment = UIAction(
                title: "Comment…",
                image: UIImage(systemName: "text.bubble")
            ) { _ in
                annotationContext.model.beginComment(
                    quote: quote,
                    messageID: annotationContext.messageID,
                    role: annotationContext.role
                )
            }
            return UIMenu(children: suggestedActions + [comment])
        }
    }
#endif
