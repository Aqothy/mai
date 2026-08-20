#if os(iOS)
import Testing

@testable import mai

struct ChatMessageAttachmentsTests {
    private let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    @Test
    func decodesAndDownsamplesInlineImageOffMainActor() async throws {
        let image = try await ChatTranscriptImageDecoder.decodeBase64(onePixelPNG)

        #expect(image.pixelWidth == 1)
        #expect(image.pixelHeight == 1)
    }

    @Test
    func acceptsRawBase64AndDataURLRepresentations() {
        let raw = Attachment(
            data: onePixelPNG,
            kind: "image",
            mimeType: "image/png",
            name: "pixel.png",
            uri: nil
        )
        let dataURL = Attachment(
            data: nil,
            kind: "image",
            mimeType: "image/png",
            name: "pixel.png",
            uri: "data:image/png;base64,\(onePixelPNG)"
        )

        #expect(
            ChatMessageAttachmentPresentation.inlineImagePayload(from: raw)
                == onePixelPNG
        )
        #expect(
            ChatMessageAttachmentPresentation.inlineImagePayload(from: dataURL)
                == onePixelPNG
        )
    }

    @Test
    func refusesOversizedEncodedPayloadBeforeDecoding() {
        #expect(throws: ChatTranscriptImageLoadingError.encodedPayloadTooLarge) {
            try ChatTranscriptImageDecoder.validateEncodedCharacterCount(
                ChatTranscriptImageDecoder.maximumEncodedCharacterCount + 1
            )
        }
    }

    @Test
    func preservesNonImageAttachmentPresentation() {
        let resource = Attachment(
            data: nil,
            kind: "resource",
            mimeType: "text/plain",
            name: "notes.txt",
            uri: "file:///tmp/notes.txt"
        )

        #expect(!ChatMessageAttachmentPresentation.isImage(resource))
        #expect(ChatMessageAttachmentPresentation.displayName(resource) == "notes.txt")
        #expect(
            ChatMessageAttachmentPresentation.inlineImagePayload(from: resource) == nil
        )
    }

    @Test
    func providerAttachmentLinksUseTheSafeMarkdownPolicy() {
        #expect(
            ChatMarkdownLinkPolicy.url(for: "https://example.com/reference") != nil
        )
        #expect(ChatMarkdownLinkPolicy.url(for: "javascript:alert(1)") == nil)
        #expect(ChatMarkdownLinkPolicy.url(for: "file:///private/secret") == nil)
    }

    @Test
    func uriOnlyImageResourceRemainsALink() {
        let resource = Attachment(
            data: nil,
            kind: "resource_link",
            mimeType: "image/png",
            name: "preview.png",
            uri: "https://example.com/preview.png"
        )

        #expect(ChatMessageAttachmentPresentation.isImage(resource))
        #expect(!ChatMessageAttachmentPresentation.isInlineImage(resource))
    }
}
#endif
