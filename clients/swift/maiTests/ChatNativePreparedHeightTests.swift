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
            let table = ChatMarkdownTable(
                alignments: [.leading, .trailing],
                header: [AttributedString("Name"), AttributedString("Value")],
                rows: [[AttributedString("Long table cell"), AttributedString("42")]])
            let prose = ChatMarkdownProseRun(
                source: "resolved quote",
                pieces: [
                    .text(AttributedString("Resolved text with several words for wrapping.")),
                    .quote(AttributedString("A nested quotation that needs complete height.")),
                    .thematicBreak,
                ])
            let tableSource = "| Name | Value |\n| --- | ---: |\n| Long table cell | 42 |"
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
