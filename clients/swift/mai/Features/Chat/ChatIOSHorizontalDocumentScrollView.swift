#if os(iOS)
    import UIKit

    /// A horizontal-only scroll container for a document of known size.
    /// UIKit sends a vertical pan over it to the enclosing chat timeline,
    /// because this view has nothing to scroll that way.
    class ChatHorizontalDocumentScrollView: UIScrollView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var documentView: UIView? {
            didSet {
                oldValue?.removeFromSuperview()
                if let documentView {
                    addSubview(documentView)
                }
                setNeedsLayout()
            }
        }

        /// The document's natural size; the document is at least as wide as
        /// the viewport so short content still fills the row.
        var documentSize: CGSize = .zero {
            didSet {
                if documentSize != oldValue {
                    setNeedsLayout()
                }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            showsVerticalScrollIndicator = false
            alwaysBounceVertical = false
            isDirectionalLockEnabled = true
            contentInsetAdjustmentBehavior = .never
            // Only the transcript may answer the status-bar tap.
            scrollsToTop = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let size = CGSize(
                width: max(bounds.width, documentSize.width),
                height: documentSize.height)
            if contentSize != size {
                contentSize = size
            }
            if let documentView, documentView.frame.size != size {
                documentView.frame = CGRect(origin: .zero, size: size)
            }
        }
    }
#endif
