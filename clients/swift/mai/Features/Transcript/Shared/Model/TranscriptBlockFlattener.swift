import CoreGraphics
import Foundation

/// Presentation and nesting metadata for a bounded prose slice produced by
/// `TranscriptBlockFlattener`. Keeps normal blocks at `.default` while letting
/// giant lists, blockquotes, paragraphs, user messages, thoughts, and future
/// message kinds share one uniform `<= 8 KB` layout unit without pre-parse
/// Markdown seam bugs.
nonisolated struct TranscriptBlockContext: Hashable, Sendable {
    enum Presentation: Hashable, Sendable {
        case assistant
        case thought
        /// Full-width connected bubble slice for large multi-slice user prompts.
        case userBubble
    }

    enum ListMarker: Hashable, Sendable {
        case bullet(depth: Int)
        case ordered(Int)
        case task(checked: Bool)
    }

    /// Ordered enclosing container stack so arbitrary nesting (e.g. a quote
    /// inside a list item, or a list inside a quote) preserves exact quote-bar
    /// x-positions and list indents.
    enum Container: Hashable, Sendable {
        case quote
        case list
    }

    var presentation: Presentation = .assistant
    var containers: [Container] = []
    var listMarker: ListMarker?
    /// True when this slice continues a parent block/item with reduced or zero
    /// vertical spacing above.
    var joinsAbove: Bool = false
    /// True when a continuation slice follows immediately below.
    var joinsBelow: Bool = false
    /// Spacing above when `joinsAbove` is true: `.none` (same paragraph/slice),
    /// `.tight` (tight list sibling), or `.block` (separate block inside a
    /// flattened quote, list item, or user bubble).
    var joinSpacingAbove: JoinSpacing = .none

    enum JoinSpacing: Hashable, Sendable {
        case none
        case tight
        case block
    }

    static let `default` = TranscriptBlockContext()

    var hasQuoteBars: Bool { containers.contains(.quote) }

    var listDepth: Int {
        var count = 0
        for container in containers where container == .list { count += 1 }
        return count
    }

    /// True when nested inside a flattened container (quote, list item, user
    /// bubble, or thought), where `.code` and `.table` render inline via
    /// `AttributedTextBuilder` rather than as standalone top-level cards.
    var isNestedInContainer: Bool {
        presentation == .userBubble || presentation == .thought || !containers.isEmpty
    }

    func spacingAbove(_ position: TranscriptBlockPosition, style: TextStyle) -> CGFloat {
        if joinsAbove {
            switch joinSpacingAbove {
            case .none: return 0
            case .tight: return style.listItemSpacing
            case .block: return style.blockSpacing
            }
        }
        switch presentation {
        case .assistant:
            return position.spacingAbove(style)
        case .thought:
            return position.isFirst ? 4 : style.blockSpacing
        case .userBubble:
            return style.messageVerticalInset
        }
    }

    func spacingBelow(_ position: TranscriptBlockPosition, style: TextStyle) -> CGFloat {
        if joinsBelow { return 0 }
        switch presentation {
        case .assistant:
            return position.spacingBelow(style)
        case .thought:
            return position.isLast ? 4 : 0
        case .userBubble:
            return style.messageVerticalInset
        }
    }
}

/// Flattens parsed `[MarkdownBlock]` of any message kind into bounded
/// `TranscriptRowKind` units (`<= maxSliceBytes` per prose row).
///
/// Normal blocks (`<= 4 KB`) pass through untouched (zero extra rows for
/// everyday chats). Giant lists, quotes, user messages, thoughts, and
/// multi-hundred-KB single paragraphs/list items are recursively bounded into
/// `<= 4 KB` slices so CoreText layout, cache retention, sync blanking
/// fallback, and initial open stay strictly O(viewport) even on 20 MB+ chats.
nonisolated enum TranscriptBlockFlattener {
    /// Maximum UTF-8 bytes per prose row before flattening/slicing. Matched to
    /// `TranscriptController.syncFallbackByteLimit` so every flattened slice is
    /// eligible for bounded-budget synchronous fallback on fast scrollbar scrubs.
    static let maxSliceBytes = 4_096

    /// Produces the row kinds for a parsed message's `blocks`.
    static func kinds(
        for blocks: [MarkdownBlock], kind: TranscriptMessage.Kind
    ) -> [TranscriptRowKind] {
        switch kind {
        case .user:
            let total = totalBytes(blocks)
            if total <= maxSliceBytes {
                return [.userMessage(blocks)]
            }
            return flattenBlocks(blocks, presentation: .userBubble)
        case .thought:
            let total = totalBytes(blocks)
            if total <= maxSliceBytes {
                return [.thought(blocks)]
            }
            return flattenBlocks(blocks, presentation: .thought)
        case .assistant:
            return flattenBlocks(blocks, presentation: .assistant)
        }
    }

    private struct Slice {
        var block: MarkdownBlock
        var context: TranscriptBlockContext
    }

    private static func flattenBlocks(
        _ blocks: [MarkdownBlock], presentation: TranscriptBlockContext.Presentation
    ) -> [TranscriptRowKind] {
        var slices: [Slice] = []
        slices.reserveCapacity(blocks.count)
        let isConnected = presentation == .userBubble
        for (index, block) in blocks.enumerated() {
            var base = TranscriptBlockContext(presentation: presentation)
            if isConnected, index > 0 {
                base.joinsAbove = true
                base.joinSpacingAbove = .block
            }
            append(block, context: base, to: &slices)
        }
        if isConnected, slices.count > 1 {
            for index in slices.indices {
                if index > 0 { slices[index].context.joinsAbove = true }
                if index + 1 < slices.count { slices[index].context.joinsBelow = true }
            }
        }
        let count = slices.count
        return slices.enumerated().map { index, slice in
            let position = TranscriptBlockPosition(isFirst: index == 0, isLast: index == count - 1)
            return .markdownBlock(slice.block, position, slice.context)
        }
    }

    private static func append(
        _ block: MarkdownBlock, context: TranscriptBlockContext, to slices: inout [Slice]
    ) {
        switch block {
        case .code, .table, .rule:
            // Top-level code blocks use 2D-virtualized `CodeLayout`; inside a
            // user bubble/thought/quote/list, code renders as inline monospace
            // prose, so slice giant nested code blocks by newline.
            if case .code(let lang, let code) = block,
                context.isNestedInContainer,
                code.utf8.count > maxSliceBytes
            {
                appendLargeCodeProse(language: lang, code: code, context: context, to: &slices)
                return
            }
            slices.append(Slice(block: block, context: context))

        case .paragraph(let inlines):
            if inlineBytes(inlines) <= maxSliceBytes {
                slices.append(Slice(block: block, context: context))
            } else {
                appendSlicedInlines(inlines, headingLevel: nil, context: context, to: &slices)
            }

        case .heading(let level, let inlines):
            if inlineBytes(inlines) <= maxSliceBytes {
                slices.append(Slice(block: block, context: context))
            } else {
                appendSlicedInlines(inlines, headingLevel: level, context: context, to: &slices)
            }

        case .quote(let children):
            if blockBytes(block) <= maxSliceBytes {
                slices.append(Slice(block: block, context: context))
                return
            }
            let startIndex = slices.count
            for (childIndex, child) in children.enumerated() {
                var childContext = context
                childContext.containers.append(.quote)
                childContext.listMarker = nil
                if childIndex > 0 {
                    childContext.joinsAbove = true
                    childContext.joinSpacingAbove = .block
                }
                append(child, context: childContext, to: &slices)
            }
            connectSlices(from: startIndex, to: slices.count, in: &slices)

        case .list(let list):
            if blockBytes(block) <= maxSliceBytes {
                slices.append(Slice(block: block, context: context))
                return
            }
            appendLargeList(list, context: context, to: &slices)
        }
    }

    private static func appendLargeList(
        _ list: MarkdownList, context: TranscriptBlockContext, to slices: inout [Slice]
    ) {
        let startIndex = slices.count
        var batch: [MarkdownList.Item] = []
        var batchStartOffset = 0
        var batchBytes = 0
        var emittedAny = false

        func flushBatch() {
            guard !batch.isEmpty else { return }
            let subList = MarkdownList(
                startIndex: list.startIndex.map { $0 + batchStartOffset },
                isTight: list.isTight,
                items: batch)
            var sliceContext = context
            if emittedAny {
                sliceContext.listMarker = nil
                sliceContext.joinsAbove = true
                sliceContext.joinSpacingAbove = list.isTight ? .tight : .block
            }
            slices.append(Slice(block: .list(subList), context: sliceContext))
            emittedAny = true
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
        }

        for (offset, item) in list.items.enumerated() {
            let itemSize = totalBytes(item.blocks)
            if itemSize > maxSliceBytes {
                flushBatch()
                // Single list item itself exceeds 8 KB (e.g. a 1 MB list item):
                // flatten its children while attaching the list marker to the
                // first paragraph slice — or emitting a separate marker line
                // above a non-paragraph first child (quote/list/code), matching
                // `AttributedTextBuilder.beginItem`.
                let marker: TranscriptBlockContext.ListMarker =
                    if let checked = item.taskChecked {
                        .task(checked: checked)
                    } else if let start = list.startIndex {
                        .ordered(start + offset)
                    } else {
                        .bullet(depth: context.listDepth)
                    }
                let firstIsParagraph: Bool =
                    if case .paragraph? = item.blocks.first { true } else { false }
                if !firstIsParagraph {
                    var markerContext = context
                    markerContext.containers.append(.list)
                    markerContext.listMarker = marker
                    if emittedAny {
                        markerContext.joinsAbove = true
                        markerContext.joinSpacingAbove = list.isTight ? .tight : .block
                    }
                    slices.append(Slice(block: .paragraph([]), context: markerContext))
                    emittedAny = true
                }
                for (childIndex, child) in item.blocks.enumerated() {
                    var childContext = context
                    childContext.containers.append(.list)
                    if childIndex == 0, firstIsParagraph {
                        childContext.listMarker = marker
                        if emittedAny {
                            childContext.joinsAbove = true
                            childContext.joinSpacingAbove = list.isTight ? .tight : .block
                        }
                    } else {
                        childContext.listMarker = nil
                        childContext.joinsAbove = true
                        childContext.joinSpacingAbove =
                            (childIndex == 0 && !firstIsParagraph) ? .none : (list.isTight ? .tight : .block)
                    }
                    append(child, context: childContext, to: &slices)
                    emittedAny = true
                }
                continue
            }
            if !batch.isEmpty, batchBytes + itemSize > maxSliceBytes {
                flushBatch()
            }
            if batch.isEmpty { batchStartOffset = offset }
            batch.append(item)
            batchBytes += itemSize
        }
        flushBatch()
        connectSlices(from: startIndex, to: slices.count, in: &slices)
    }

    private static func appendSlicedInlines(
        _ inlines: [MarkdownInline], headingLevel: Int?, context: TranscriptBlockContext, to slices: inout [Slice]
    ) {
        let startIndex = slices.count
        var current: [MarkdownInline] = []
        var currentBytes = 0
        var isFirstSlice = true

        func emit() {
            guard !current.isEmpty else { return }
            var sliceContext = context
            if !isFirstSlice {
                sliceContext.listMarker = nil
                sliceContext.joinsAbove = true
                sliceContext.joinSpacingAbove = .none
            }
            let block: MarkdownBlock =
                if let headingLevel { .heading(level: headingLevel, current) } else { .paragraph(current) }
            slices.append(Slice(block: block, context: sliceContext))
            isFirstSlice = false
            current.removeAll(keepingCapacity: true)
            currentBytes = 0
        }

        for inline in inlines {
            let text = inline.text
            let utf8 = text.utf8
            if currentBytes + utf8.count <= maxSliceBytes {
                current.append(inline)
                currentBytes += utf8.count
                continue
            }
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let remainingAllowance = maxSliceBytes - currentBytes
                if remainingAllowance <= 0 {
                    emit()
                    continue
                }
                let remainingBytes = utf8.distance(from: cursor, to: text.endIndex)
                if remainingBytes <= remainingAllowance {
                    var part = inline
                    part.text = String(text[cursor..<text.endIndex])
                    current.append(part)
                    currentBytes += remainingBytes
                    break
                }
                let target = utf8.index(cursor, offsetBy: remainingAllowance)
                let split = splitPoint(in: text, from: cursor, upTo: target)
                if split.end == cursor {
                    if !current.isEmpty {
                        emit()
                        continue
                    }
                    // Single unbroken token longer than `maxSliceBytes`: cut at
                    // a Character boundary so we always make progress.
                    let forced = text.index(after: cursor)
                    var part = inline
                    part.text = String(text[cursor..<forced])
                    current.append(part)
                    currentBytes += utf8.distance(from: cursor, to: forced)
                    cursor = forced
                    emit()
                    continue
                }
                var part = inline
                part.text = String(text[cursor..<split.end])
                current.append(part)
                currentBytes += utf8.distance(from: cursor, to: split.end)
                cursor = split.next
                emit()
            }
        }
        emit()
        connectSlices(from: startIndex, to: slices.count, in: &slices)
    }

    private static func appendLargeCodeProse(
        language: String?, code: String, context: TranscriptBlockContext, to slices: inout [Slice]
    ) {
        let startIndex = slices.count
        var cursor = code.startIndex
        var isFirst = true
        while cursor < code.endIndex {
            let remaining = code.utf8.distance(from: cursor, to: code.endIndex)
            if remaining <= maxSliceBytes {
                var sliceContext = context
                if !isFirst {
                    sliceContext.listMarker = nil
                    sliceContext.joinsAbove = true
                    sliceContext.joinSpacingAbove = .none
                }
                slices.append(
                    Slice(block: .code(language: language, code: String(code[cursor..<code.endIndex])), context: sliceContext))
                break
            } else {
                let target = code.utf8.index(cursor, offsetBy: maxSliceBytes)
                let split = splitPoint(in: code, from: cursor, upTo: target)
                let sliceEnd = split.end > cursor ? split.end : code.index(after: cursor)
                let nextCursor = split.end > cursor ? split.next : sliceEnd
                var sliceContext = context
                if !isFirst {
                    sliceContext.listMarker = nil
                    sliceContext.joinsAbove = true
                    sliceContext.joinSpacingAbove = .none
                }
                slices.append(Slice(block: .code(language: language, code: String(code[cursor..<sliceEnd])), context: sliceContext))
                isFirst = false
                cursor = nextCursor
            }
        }
        connectSlices(from: startIndex, to: slices.count, in: &slices)
    }

    /// Marks `joinsBelow = true` on every internal slice in `startIndex..<endIndex`
    /// so connected quote bars, lists, bubbles, and split paragraphs have zero
    /// unwanted gap between slices.
    private static func connectSlices(from startIndex: Int, to endIndex: Int, in slices: inout [Slice]) {
        guard endIndex - startIndex > 1 else { return }
        for index in startIndex..<(endIndex - 1) {
            slices[index].context.joinsBelow = true
        }
    }

    /// Finds a Character-aligned split point in `from..<upTo`, preferring the
    /// last `\n` (consuming the seam newline since rows join with `\n` on
    /// copy), then the last ASCII space/tab, and finally a Character boundary
    /// at or before `upTo`.
    private static func splitPoint(
        in text: String, from start: String.Index, upTo limit: String.Index
    ) -> (end: String.Index, next: String.Index) {
        let utf8 = text.utf8
        var bounded = limit
        while bounded > start, bounded.samePosition(in: text) == nil {
            utf8.formIndex(before: &bounded)
        }
        if bounded > start {
            let cluster = text.rangeOfComposedCharacterSequence(at: text.index(before: bounded))
            bounded = cluster.upperBound <= limit ? cluster.upperBound : cluster.lowerBound
        }
        guard bounded > start else { return (start, start) }

        let minPreferred = utf8.index(start, offsetBy: utf8.distance(from: start, to: bounded) / 2)
        var lastSpace: String.Index?
        var idx = bounded
        while idx > minPreferred {
            let prev = utf8.index(before: idx)
            let byte = utf8[prev]
            if byte == 0x0A, let end = prev.samePosition(in: text), let next = idx.samePosition(in: text) {
                return (end, next)
            }
            if lastSpace == nil, byte == 0x20 || byte == 0x09, let aligned = idx.samePosition(in: text) {
                lastSpace = aligned
            }
            idx = prev
        }
        let chosen = lastSpace ?? bounded
        return (chosen, chosen)
    }

    // MARK: Byte measurement

    static func totalBytes(_ blocks: [MarkdownBlock]) -> Int {
        var total = 0
        for block in blocks { total += blockBytes(block) }
        return total
    }

    private static func blockBytes(_ block: MarkdownBlock) -> Int {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlineBytes(inlines)
        case .code(_, let code):
            return code.utf8.count
        case .list(let list):
            var total = 0
            for item in list.items { total += totalBytes(item.blocks) }
            return total
        case .quote(let children):
            return totalBytes(children)
        case .table(let table):
            var total = 0
            for cell in table.header { total += inlineBytes(cell) }
            for row in table.rows {
                for cell in row { total += inlineBytes(cell) }
            }
            return total
        case .rule(let spelling):
            return spelling.utf8.count
        }
    }

    private static func inlineBytes(_ inlines: [MarkdownInline]) -> Int {
        var total = 0
        for inline in inlines { total += inline.text.utf8.count }
        return total
    }
}
