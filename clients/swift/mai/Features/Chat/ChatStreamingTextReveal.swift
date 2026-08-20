import SwiftUI

/// One append that should reveal independently of newer streaming updates.
/// Keeping batches separate prevents a 50 ms backend update from restarting
/// the 200 ms animation of text that is already on screen.
nonisolated struct ChatStreamingTextRevealBatch: Equatable, Sendable {
    static let duration: TimeInterval = 0.2

    let characterCount: Int
    let startedAt: Date

    var deadline: Date {
        startedAt.addingTimeInterval(Self.duration)
    }

    func progress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(startedAt)
        return min(max(elapsed / Self.duration, 0), 1)
    }
}

/// Identifies the parsed trailing content that receives the renderer. A new
/// paragraph, quote, or code block starts a new reveal target instead of
/// applying old source deltas to unrelated glyphs.
nonisolated struct ChatStreamingTextRevealTarget: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case proseText(pieceIndex: Int)
            case proseQuote(pieceIndex: Int)
            case code
        }

        let stableBlockCount: Int
        let blockIndex: Int
        let content: Content
    }

    let identity: Identity?
    let characterCount: Int

    init(snapshot: ChatStreamingMarkdownSnapshot) {
        guard let blockIndex = snapshot.plan.blocks.indices.last,
            blockIndex >= snapshot.stableBlockCount
        else {
            identity = nil
            characterCount = 0
            return
        }

        switch snapshot.plan.blocks[blockIndex] {
        case .prose(let prose):
            guard let pieceIndex = prose.pieces.indices.last else {
                identity = nil
                characterCount = 0
                return
            }
            switch prose.pieces[pieceIndex] {
            case .text(let text):
                identity = Identity(
                    stableBlockCount: snapshot.stableBlockCount,
                    blockIndex: blockIndex,
                    content: .proseText(pieceIndex: pieceIndex)
                )
                characterCount = text.characters.count
            case .quote(let quote):
                identity = Identity(
                    stableBlockCount: snapshot.stableBlockCount,
                    blockIndex: blockIndex,
                    content: .proseQuote(pieceIndex: pieceIndex)
                )
                characterCount = quote.characters.count
            case .thematicBreak:
                identity = nil
                characterCount = 0
            }

        case .code(let code):
            identity = Identity(
                stableBlockCount: snapshot.stableBlockCount,
                blockIndex: blockIndex,
                content: .code
            )
            characterCount = code.code.count

        case .table:
            identity = nil
            characterCount = 0
        }
    }

    init(identity: Identity?, characterCount: Int) {
        self.identity = identity
        self.characterCount = characterCount
    }
}

/// Tracks append boundaries without retaining a second copy of the growing
/// message. State and animated glyph work stay bounded for long responses.
nonisolated struct ChatStreamingTextRevealState: Equatable, Sendable {
    static let maximumBatchCount = 8
    static let maximumAnimatedCharacterCount = 512

    private(set) var batches: [ChatStreamingTextRevealBatch] = []
    private var previousTarget: ChatStreamingTextRevealTarget?
    private var previousUpdateID: Int?

    mutating func observe(
        target: ChatStreamingTextRevealTarget,
        updateID: Int,
        sourceIsAppendOnly: Bool,
        at date: Date
    ) {
        guard let previousTarget, let previousUpdateID else {
            setBaseline(target: target, updateID: updateID)
            return
        }

        guard sourceIsAppendOnly,
            updateID > previousUpdateID
        else {
            batches.removeAll(keepingCapacity: true)
            setBaseline(target: target, updateID: updateID)
            return
        }

        batches.removeAll { $0.deadline <= date }
        defer {
            setBaseline(target: target, updateID: updateID)
        }

        guard target.identity != nil else {
            batches.removeAll(keepingCapacity: true)
            return
        }

        let appendedCharacterCount: Int
        if target.identity != previousTarget.identity {
            batches.removeAll(keepingCapacity: true)
            appendedCharacterCount = target.characterCount
        } else if target.characterCount >= previousTarget.characterCount {
            appendedCharacterCount = target.characterCount
                - previousTarget.characterCount
        } else {
            batches.removeAll(keepingCapacity: true)
            return
        }
        guard appendedCharacterCount > 0 else { return }

        batches.append(
            ChatStreamingTextRevealBatch(
                characterCount: min(
                    appendedCharacterCount,
                    Self.maximumAnimatedCharacterCount
                ),
                startedAt: date
            )
        )
        trimToBounds()
    }

    private mutating func setBaseline(
        target: ChatStreamingTextRevealTarget,
        updateID: Int
    ) {
        previousTarget = target
        previousUpdateID = updateID
    }

    private mutating func trimToBounds() {
        if batches.count > Self.maximumBatchCount {
            batches.removeFirst(batches.count - Self.maximumBatchCount)
        }

        var overflow = batches.reduce(0) { partialResult, batch in
            partialResult + batch.characterCount
        } - Self.maximumAnimatedCharacterCount

        while overflow > 0, let first = batches.first {
            if first.characterCount <= overflow {
                overflow -= first.characterCount
                batches.removeFirst()
            } else {
                batches[0] = ChatStreamingTextRevealBatch(
                    characterCount: first.characterCount - overflow,
                    startedAt: first.startedAt
                )
                overflow = 0
            }
        }
    }
}

/// Applies a short reveal to an attributed string while keeping its complete,
/// canonical value present for layout, selection, and accessibility.
struct ChatStreamingTextRevealView: View {
    let text: AttributedString
    let batches: [ChatStreamingTextRevealBatch]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || batches.isEmpty {
            Text(text)
        } else {
            TimelineView(
                .explicit(
                    ChatStreamingTextRevealTimeline.dates(
                        for: batches,
                        startingAt: .now
                    )
                )
            ) { context in
                Text(text)
                    .textRenderer(
                        ChatStreamingTextRevealRenderer(
                            batches: batches,
                            date: context.date
                        )
                    )
            }
        }
    }
}

private nonisolated enum ChatStreamingTextRevealTimeline {
    static let frameInterval: TimeInterval = 1 / 60
    static let maximumFrameCount = 16

    static func dates(
        for batches: [ChatStreamingTextRevealBatch],
        startingAt start: Date
    ) -> [Date] {
        guard let deadline = batches.map(\.deadline).max(), deadline > start
        else { return [start] }

        var dates = [start]
        var next = start.addingTimeInterval(frameInterval)
        while next < deadline, dates.count < maximumFrameCount - 1 {
            dates.append(next)
            next = next.addingTimeInterval(frameInterval)
        }
        if dates.last != deadline {
            dates.append(deadline)
        }
        return dates
    }
}

private nonisolated struct ChatStreamingTextRevealRenderer: TextRenderer {
    private struct Effect {
        let trailingGlyphOffsets: Range<Int>
        let progress: Double
    }

    let batches: [ChatStreamingTextRevealBatch]
    let date: Date

    var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let glyphCount = layout.reduce(0) { lineResult, line in
            lineResult + line.reduce(0) { runResult, run in
                runResult + run.count
            }
        }
        let effects = effects(glyphCount: glyphCount)
        guard let oldestAnimatedOffset = effects.last?.trailingGlyphOffsets.upperBound
        else {
            for line in layout {
                context.draw(line)
            }
            return
        }

        let animatedStart = max(glyphCount - oldestAnimatedOffset, 0)
        var glyphOrdinal = 0

        for line in layout {
            for run in line {
                let runStart = glyphOrdinal
                let runEnd = runStart + run.count
                if runEnd <= animatedStart {
                    context.draw(run)
                    glyphOrdinal = runEnd
                    continue
                }

                if runStart < animatedStart {
                    let stableEnd = animatedStart - runStart
                    context.draw(run[run.startIndex..<stableEnd])
                }

                let firstAnimatedIndex = max(
                    run.startIndex,
                    animatedStart - runStart
                )
                for glyphIndex in firstAnimatedIndex..<run.endIndex {
                    let trailingOffset = glyphCount - glyphOrdinal
                        - (glyphIndex - run.startIndex) - 1
                    guard let effect = effects.first(where: {
                        $0.trailingGlyphOffsets.contains(trailingOffset)
                    }) else {
                        context.draw(run[glyphIndex])
                        continue
                    }

                    let remaining = 1 - effect.progress
                    let easedProgress = 1 - (remaining * remaining)
                    var glyphContext = context
                    glyphContext.opacity *= easedProgress
                    glyphContext.translateBy(
                        x: 0,
                        y: CGFloat(remaining) * 3
                    )
                    glyphContext.draw(run[glyphIndex])
                }
                glyphOrdinal = runEnd
            }
        }
    }

    private func effects(glyphCount: Int) -> [Effect] {
        var trailingOffset = 0
        var result: [Effect] = []
        result.reserveCapacity(batches.count)

        for batch in batches.reversed() where batch.deadline > date {
            let upperBound = min(
                trailingOffset + batch.characterCount,
                glyphCount
            )
            guard upperBound > trailingOffset else { break }
            result.append(
                Effect(
                    trailingGlyphOffsets: trailingOffset..<upperBound,
                    progress: batch.progress(at: date)
                )
            )
            trailingOffset = upperBound
        }
        return result
    }
}
