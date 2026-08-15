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

            override func scrollWheel(with event: NSEvent) {
                guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                    let enclosingVerticalScrollView
                else {
                    super.scrollWheel(with: event)
                    return
                }

                enclosingVerticalScrollView.scrollWheel(with: event)
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
