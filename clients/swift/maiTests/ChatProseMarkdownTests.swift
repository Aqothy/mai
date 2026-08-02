import Foundation
import Markdown
import Testing

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@testable import mai

struct ChatMarkdownSegmentTests {
    @Test
    func smallSourcesDoNotSegment() {
        #expect(ChatMarkdownChunker.segments(of: "Short **reply**.") == nil)
    }

    @Test
    func proseOnlyEssayIsOneUnboundedProseSegment() throws {
        let source = proseEssay(sectionCount: 20)
        let segments = try #require(ChatMarkdownChunker.segments(of: source))

        #expect(segments.count == 1)
        #expect(segments[0].kind == .prose)
        #expect(segments[0].source == source)
    }

    @Test
    func codeFencesIsolateAsRichSegmentsAndProseStaysContiguous() throws {
        let prose = proseEssay(sectionCount: 6)
        let fence = "```swift\nlet value = \"payload\"\n```"
        let source = [prose, fence, prose, fence, prose].joined(separator: "\n\n")
        let segments = try #require(ChatMarkdownChunker.segments(of: source))

        #expect(segments.map(\.kind) == [.prose, .rich, .prose, .rich, .prose])
        #expect(segments.map(\.source).joined() == source)
        for segment in segments where segment.kind == .rich {
            let document = Markdown.Document(parsing: segment.source)
            #expect(document.childCount == 1)
            #expect(document.children.first(where: { $0 is CodeBlock }) != nil)
        }
    }

    @Test
    func listWrappingAFenceIsRichAsAWhole() throws {
        let prose = proseEssay(sectionCount: 8)
        let listWithFence = """
            - first point
            - second point with a snippet:
              ```swift
              let nested = true
              ```
            """
        let source = [prose, listWithFence, prose].joined(separator: "\n\n")
        let segments = try #require(ChatMarkdownChunker.segments(of: source))

        #expect(segments.map(\.kind) == [.prose, .rich, .prose])
        #expect(segments.map(\.source).joined() == source)
    }

    @Test
    func imagesAndHTMLBecomeRichSegments() throws {
        let prose = proseEssay(sectionCount: 8)
        let image = "![diagram](https://example.com/diagram.png)"
        let source = [prose, image, prose].joined(separator: "\n\n")
        let segments = try #require(ChatMarkdownChunker.segments(of: source))

        #expect(segments.map(\.kind) == [.prose, .rich, .prose])
        #expect(segments.map(\.source).joined() == source)
    }

    @Test
    func mathAndReferenceDefinitionsDisableSegments() {
        let prose = proseEssay(sectionCount: 12)
        #expect(ChatMarkdownChunker.segments(of: prose + "\n\n$$x^2$$") == nil)
        #expect(ChatMarkdownChunker.segments(of: prose + "\n\nInline \\(x\\) math.") == nil)
        #expect(ChatMarkdownChunker.segments(of: prose + "\n\nThe value $x+y$ holds.") == nil)
        #expect(
            ChatMarkdownChunker.segments(
                of: prose + "\n\nSee [docs][ref].\n\n[ref]: https://example.com"
            ) == nil
        )
    }

    /// Roughly 400 bytes per section, so single-digit section counts already
    /// clear the chunker's oversized gate.
    private func proseEssay(sectionCount: Int) -> String {
        (1...sectionCount).flatMap { index -> [String] in
            let heading = "## Section \(index)"
            var paragraph = "Paragraph \(index) provides enough prose to keep "
            paragraph += "the source oversized while remaining free of rich "
            paragraph += "blocks entirely. It repeats a second sentence so "
            paragraph += "every section carries realistic weight for the "
            paragraph += "segmenter's size gate, and a third sentence so a "
            paragraph += "handful of sections is plenty."
            let list = "- point one for \(index)\n- point two for \(index)"
            return [heading, paragraph, list]
        }.joined(separator: "\n\n")
    }
}

struct ChatProseMarkdownRendererTests {
    @Test
    func paragraphsRenderWithoutMarkdownTokens() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "A paragraph with **strong**, *emphasis*, and `code`."
        )
        #expect(rendered.string.contains("A paragraph with strong, emphasis, and code."))
        #expect(!rendered.string.contains("**"))
        #expect(!rendered.string.contains("`"))
    }

    @Test
    func strongTextCarriesABoldFont() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "Plain then **weighty** words."
        )
        let location = (rendered.string as NSString).range(of: "weighty").location
        let font = rendered.attribute(.font, at: location, effectiveRange: nil)
            as? ChatProsePlatformFont
        #expect(font.map(isBold) == true)
    }

    @Test
    func headingsUseLargerFontsThanBody() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "## Title\n\nBody text."
        )
        let headingLocation = (rendered.string as NSString).range(of: "Title").location
        let bodyLocation = (rendered.string as NSString).range(of: "Body").location
        let headingFont = rendered.attribute(.font, at: headingLocation, effectiveRange: nil)
            as? ChatProsePlatformFont
        let bodyFont = rendered.attribute(.font, at: bodyLocation, effectiveRange: nil)
            as? ChatProsePlatformFont
        #expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? .infinity))
    }

    @Test
    func listsRenderMarkersAndContent() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "1. first\n2. second\n\n- alpha\n- beta"
        )
        #expect(rendered.string.contains("1. first"))
        #expect(rendered.string.contains("2. second"))
        #expect(rendered.string.contains("• "))
        #expect(rendered.string.contains("alpha"))
    }

    @Test
    func outputHasNoTrailingNewline() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "One.\n\nTwo."
        )
        #expect(!rendered.string.hasSuffix("\n"))
        #expect(rendered.length > 0)
    }

    @Test
    func layoutHeightsAreDeterministicAndWidthSensitive() {
        let source = (1...30).map { index in
            "Paragraph \(index) has enough words to wrap across several lines "
                + "at narrow widths and fewer lines at wide ones."
        }.joined(separator: "\n\n")

        let narrowA = ChatProseTextLayout(source: source, width: 320)
        let narrowB = ChatProseTextLayout(source: source, width: 320)
        let wide = ChatProseTextLayout(source: source, width: 700)

        #expect(narrowA.height > 0)
        #expect(narrowA.height == narrowB.height)
        #expect(wide.height < narrowA.height)
    }

    private func isBold(_ font: ChatProsePlatformFont) -> Bool {
        #if canImport(UIKit)
            font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
            font.fontDescriptor.symbolicTraits.contains(.bold)
        #endif
    }
}
