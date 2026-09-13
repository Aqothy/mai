#if os(macOS)
    import Foundation

    /// Completed native rows have value-based geometry inputs. Interactive rows
    /// report their current height from their live SwiftUI view instead.
    enum ChatNativeRowMeasurementKey: Equatable {
        case source(String, role: String, first: Bool, last: Bool)
        case resolved(ChatResolvedMarkdownRowContent, first: Bool, last: Bool)
    }

    extension ChatTimelineRenderRow {
        var nativeMeasurementKey: ChatNativeRowMeasurementKey? {
            switch self {
            case .prose(let segment), .richMarkdown(let segment):
                guard segment.attachments?.isEmpty != false, segment.annotations?.isEmpty != false else { return nil }
                return .source(
                    segment.source, role: segment.role, first: segment.isFirst, last: segment.isLast
                )
            case .resolvedMarkdown(let block):
                guard block.attachments?.isEmpty != false else { return nil }
                return .resolved(block.content, first: block.isFirst, last: block.isLast)
            case .standard: return nil
            }
        }
    }
#endif
