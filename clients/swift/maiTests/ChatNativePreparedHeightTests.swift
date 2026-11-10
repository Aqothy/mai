#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import mai

    struct ChatNativePreparedHeightTests {
        @Test @MainActor func preparedGeometryMatchesExistingSwiftUIRows() throws {
            let store = ThreadStore()
            let layouts = ChatTextLayoutStore()
            let fold = ChatTimelineFoldModel()
            let scroll = ChatScrollState()
            let tableSource = "| Name | Value |\n| --- | ---: |\n| Long table cell | 42 |"
            let resolved = ChatMarkdownRenderPlanner.plan(
                from: "Resolved text with several words for wrapping.\n\n"
                    + "> A nested quotation that needs complete height.\n\n---\n\n"
                    + tableSource)
            guard case .prose(let prose) = resolved.blocks.first,
                case .table(let table) = resolved.blocks.last
            else {
                Issue.record("Expected a prose run followed by a table")
                return
            }
            _ = ChatMarkdownRenderCache.shared.plan(
                messageID: "rich-table#segment-0", source: tableSource)
            for width: CGFloat in [220, 380, 760] {
                for first in [false, true] {
                    for last in [false, true] {
                        let rows: [ChatTimelineRenderRow] = [
                            .richMarkdown(
                                .init(
                                    messageID: "rich-table", index: 0, source: tableSource,
                                    role: "assistant", annotations: nil, attachments: nil, isFirst: first,
                                    isLast: last)),
                            .prose(
                                .init(
                                    messageID: "short", index: 0, source: "A short paragraph",
                                    role: "assistant", annotations: nil, attachments: nil, isFirst: first,
                                    isLast: last)),
                            .prose(
                                .init(
                                    messageID: "long", index: 0,
                                    source: String(
                                        repeating: "A **formatted** paragraph with wrapping. ",
                                        count: 40), role: "assistant", annotations: nil, attachments: nil,
                                    isFirst: first, isLast: last)),
                            .resolvedMarkdown(
                                .init(
                                    messageID: "resolved", index: 0, content: .proseRun(prose),
                                    attachments: nil, isFirst: first, isLast: last)),
                            .resolvedMarkdown(
                                .init(
                                    messageID: "table", index: 0, content: .table(table),
                                    attachments: nil, isFirst: first, isLast: last)),
                        ]
                        for row in rows {
                            let descriptor = try #require(
                                ChatNativePreparedRow.descriptor(for: row))
                            let prepared = try #require(
                                ChatNativePreparedRow.preparedHeight(
                                    for: descriptor, width: width, store: layouts))
                            let host = NSHostingController(
                                rootView: ChatTimelineRenderRowView(
                                    row: row, streamingTurnID: nil, threadID: "height-test",
                                    store: store,
                                    foldModel: fold, scrollState: scroll, annotationModel: ChatAnnotationModel(), textLayoutStore: layouts
                                ).frame(width: width))
                            let measured = ceil(
                                host.sizeThatFits(
                                    in: CGSize(width: width, height: .greatestFiniteMagnitude)
                                ).height)
                            #expect(
                                prepared == measured,
                                "\(row.id), width \(width), first \(first), last \(last)")
                        }
                    }
                }
            }
        }
    }
#endif
