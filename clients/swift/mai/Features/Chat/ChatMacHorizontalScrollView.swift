#if os(macOS)
    import AppKit
    import SwiftUI

    /// A horizontal-only scroll container that lets vertical wheel gestures
    /// continue through the enclosing chat timeline.
    struct ChatMacHorizontalScrollView<Content: View>: NSViewRepresentable {
        private let content: Content

        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(content: content)
        }

        func makeNSView(context: Context) -> HorizontalScrollView {
            let scrollView = HorizontalScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .automatic
            scrollView.verticalScrollElasticity = .none
            scrollView.documentView = context.coordinator.hostingView
            return scrollView
        }

        func updateNSView(
            _ scrollView: HorizontalScrollView,
            context: Context
        ) {
            context.coordinator.hostingView.rootView = LeadingContent(
                content: content
            )
            scrollView.needsLayout = true
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: HorizontalScrollView,
            context: Context
        ) -> CGSize? {
            let contentSize = context.coordinator.hostingView.fittingSize
            return CGSize(
                width: proposal.width ?? contentSize.width,
                height: contentSize.height
            )
        }

        struct LeadingContent<WrappedContent: View>: View {
            let content: WrappedContent

            var body: some View {
                HStack(spacing: 0) {
                    content
                    Spacer(minLength: 0)
                }
            }
        }

        final class Coordinator {
            let hostingView: NSHostingView<LeadingContent<Content>>

            init(content: Content) {
                hostingView = NSHostingView(
                    rootView: LeadingContent(content: content)
                )
            }
        }

        final class HorizontalScrollView: NSScrollView {
            override func layout() {
                super.layout()
                guard let documentView else { return }
                let fittingSize = documentView.fittingSize
                let documentSize = CGSize(
                    width: max(contentSize.width, fittingSize.width),
                    height: fittingSize.height
                )
                guard documentView.frame.size != documentSize else { return }
                documentView.setFrameSize(documentSize)
            }

            /// AppKit sends one diagonal trackpad event to the deepest scroll
            /// view. Split its axes at that boundary: this view owns x and the
            /// transcript owns y. A dominance heuristic makes the route flip
            /// during a gesture and drops the smaller axis, which is the
            /// stuttering/"stuck over code" behavior this wrapper prevents.
            override func scrollWheel(with event: NSEvent) {
                let hasHorizontalDelta = abs(event.scrollingDeltaX) > 0
                let hasVerticalDelta = abs(event.scrollingDeltaY) > 0

                if hasHorizontalDelta {
                    super.scrollWheel(with: event)
                }
                if hasVerticalDelta, let enclosingVerticalScrollView {
                    enclosingVerticalScrollView.scrollWheel(with: event)
                }
                if !hasHorizontalDelta, !hasVerticalDelta {
                    super.scrollWheel(with: event)
                }
            }

            private var enclosingVerticalScrollView: NSScrollView? {
                var candidate = superview
                while let view = candidate {
                    if let scrollView = view as? NSScrollView {
                        return scrollView
                    }
                    candidate = view.superview
                }
                return nil
            }
        }
    }
#endif
