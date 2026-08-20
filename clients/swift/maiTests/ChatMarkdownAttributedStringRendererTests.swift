import Foundation
import SwiftUI
import Testing

@testable import mai

struct ChatMarkdownAttributedStringRendererTests {
    @Test
    func rendersProseWithoutMarkdownDelimiters() throws {
        let rendered = ChatMarkdownAttributedStringRenderer.attributedString(
            from: "# Heading\n\nA **bold** line with `code`.\n\n- First\n- Second"
        )
        let text = String(rendered.characters)

        #expect(
            text
                == "Heading\n\nA bold line with code.\n\n•  First\n•  Second"
        )
        #expect(!text.contains("**"))

        let boldRange = try #require(rendered.range(of: "bold"))
        #expect(
            rendered[boldRange].inlinePresentationIntent?
                .contains(.stronglyEmphasized) == true
        )

        let codeRange = try #require(rendered.range(of: "code"))
        #expect(
            rendered[codeRange].inlinePresentationIntent?.contains(.code)
                == true
        )
        #expect(rendered[codeRange].font != nil)
    }

    @Test
    func preservesNestedListsQuotesAndHardBreaks() {
        let rendered = ChatMarkdownAttributedStringRenderer.attributedString(
            from: """
                > Quoted line

                3. Parent
                   - Nested

                First line  
                second line
                """
        )

        #expect(
            String(rendered.characters)
                == "Quoted line\n\n3.  Parent\n    ◦  Nested\n\nFirst line\nsecond line"
        )
    }

    @Test
    func keepsConsecutiveProseInOneAttributedSelectionValue() {
        let content = ChatMarkdownAttributedStringRenderer.attributedString(
            from: "Before\n\n> Quote\n>\n> > Nested\n\n---\n\nAfter"
        )
        let plainText = String(content.characters)

        #expect(plainText.hasPrefix("Before\n\nQuote"))
        #expect(plainText.contains("▏") == false)
        #expect(plainText.contains("────────────"))
        #expect(plainText.hasSuffix("After"))
    }

    @Test
    func keepsRemoteAndExecutableNodesInert() {
        let rendered = ChatMarkdownAttributedStringRenderer.attributedString(
            from: """
                <script>alert('inert')</script>

                ![Architecture](https://example.invalid/diagram.png)
                """
        )
        let text = String(rendered.characters)

        #expect(text.contains("<script>alert('inert')</script>"))
        #expect(
            text.contains(
                "![Architecture](https://example.invalid/diagram.png)"
            )
        )
    }

    @Test
    func onlySupportedLinkDestinationsAreInteractive() throws {
        let rendered = ChatMarkdownAttributedStringRenderer.attributedString(
            from: "[Web](https://example.com/docs), [email](mailto:hello@example.com), [relative](/docs), [custom](javascript:alert%281%29)."
        )

        let web = try #require(rendered.range(of: "Web"))
        let email = try #require(rendered.range(of: "email"))
        let relative = try #require(rendered.range(of: "relative"))
        let custom = try #require(rendered.range(of: "custom"))

        #expect(rendered[web].link == URL(string: "https://example.com/docs"))
        #expect(rendered[email].link == URL(string: "mailto:hello@example.com"))
        #expect(rendered[relative].link == nil)
        #expect(rendered[custom].link == nil)
    }

}
