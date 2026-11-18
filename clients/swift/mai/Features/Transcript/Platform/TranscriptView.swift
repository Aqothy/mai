import SwiftUI

/// Hosts the transcript's scroll view in SwiftUI. SwiftUI never updates it
/// per streamed chunk: the controller observes the store itself. It passes
/// in what only SwiftUI knows: the Comment and fork actions and, on iOS, the
/// insets of the bars, composer and keyboard over it.
struct TranscriptView {
    let controller: TranscriptController
    /// Starts a Comment on selected text: quote, message ID, role.
    var onComment: ((String, String?, String?) -> Void)?
    /// The fork menu of a finished turn, by turn ID.
    var forkMenu: ((String) -> TranscriptMenu?)?
    #if os(iOS)
        var insets = EdgeInsets()

        func viewportInsets(_ insets: EdgeInsets) -> TranscriptView {
            var view = self
            view.insets = insets
            return view
        }
    #endif
}

#if os(macOS)
    extension TranscriptView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.documentView = TranscriptDocumentView(controller: controller)
            updateNSView(scrollView, context: context)
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            if (scrollView.documentView as? TranscriptDocumentView)?.controller !== controller {
                scrollView.documentView = TranscriptDocumentView(controller: controller)
            }
            let document = scrollView.documentView as? TranscriptDocumentView
            document?.onComment = onComment
            document?.forkMenu = forkMenu
        }
    }
#else
    extension TranscriptView: UIViewRepresentable {
        func makeUIView(context: Context) -> TranscriptScrollView {
            let scrollView = TranscriptScrollView(controller: controller)
            updateUIView(scrollView, context: context)
            return scrollView
        }

        func updateUIView(_ scrollView: TranscriptScrollView, context: Context) {
            scrollView.onComment = onComment
            scrollView.forkMenu = forkMenu
            scrollView.setViewportInsets(UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        }
    }
#endif
