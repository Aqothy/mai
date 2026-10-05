#if os(iOS)
    import Testing
    import UIKit

    @testable import mai

    @MainActor
    struct ChatSelectableTextMenuTests {
        /// iOS 18 only asks the delegate for the single-range edit menu, so
        /// Comment must come from that callback on every supported runtime.
        @Test
        func commentIsOfferedThroughSupportedSingleRangeCallback() throws {
            let coordinator = ChatSelectableText.Coordinator()
            coordinator.annotationContext = ChatAnnotationContext(
                messageID: "message-1",
                role: "assistant",
                model: ChatAnnotationModel()
            )
            let singleRange = #selector(
                UITextViewDelegate.textView(_:editMenuForTextIn:suggestedActions:)
            )
            #expect(coordinator.responds(to: singleRange))

            let textView = UITextView()
            textView.attributedText = NSAttributedString(string: "Prose 雪 e\u{301} 🧪 tail")
            let copy = UIAction(title: "Copy") { _ in }
            let menu = try #require(
                coordinator.textView(
                    textView,
                    editMenuForTextIn: NSRange(location: 6, length: 7),
                    suggestedActions: [copy]
                )
            )
            #expect(menu.children.map(\.title) == ["Copy", "Comment…"])

            let empty = try #require(
                coordinator.textView(
                    textView,
                    editMenuForTextIn: NSRange(location: 6, length: 0),
                    suggestedActions: [copy]
                )
            )
            #expect(empty.children.map(\.title) == ["Copy"])
        }
    }
#endif
