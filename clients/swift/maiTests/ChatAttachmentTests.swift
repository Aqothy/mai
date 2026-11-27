import CoreGraphics
import Foundation
import Testing
@testable import mai

struct ChatAttachmentTests {
    @Test
    func distinctImagePixelsSurviveDecodingDespiteMatchingPayloadEnds() async throws {
        let red = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAABE0lEQVR4AQEIAff+APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/APAoFP/wKBT/8CgU//AoFP/wKBT/8CgU//AoFP/wKBT/jRGKwc4GaxoAAACAdEVYdENvbW1lbnQAZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgY1zTCgAAAABJRU5ErkJggg=="
        let blue = "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAABE0lEQVR4AQEIAff+ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/ABQo8P8UKPD/FCjw/xQo8P8UKPD/FCjw/xQo8P8UKPD/HxGKweXLRFgAAACAdEVYdENvbW1lbnQAZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgZml4dHVyZSBjb21tb24gbWV0YWRhdGEgY1zTCgAAAABJRU5ErkJggg=="
        let first = try await ChatTranscriptImageDecoder.decodeBase64(red)
        let second = try await ChatTranscriptImageDecoder.decodeBase64(blue)
        #expect(first.cgImage.width == 8)
        #expect(first.cgImage.height == 8)
        #expect(second.cgImage.width == 8)
        let firstPixels = try #require(first.cgImage.dataProvider?.data)
        let secondPixels = try #require(second.cgImage.dataProvider?.data)
        #expect((firstPixels as Data) != (secondPixels as Data))
    }

    @Test
    func malformedAndOversizedImagePayloadsFailWithoutRendering() async {
        for payload in ["", "%%%%", Data("not an image".utf8).base64EncodedString()] {
            await #expect(throws: ChatTranscriptImageLoadingError.invalidImage) {
                try await ChatTranscriptImageDecoder.decodeBase64(payload)
            }
        }
        let oversized = String(repeating: "A", count: ChatTranscriptImageDecoder.maximumEncodedCharacterCount + 1)
        await #expect(throws: ChatTranscriptImageLoadingError.encodedPayloadTooLarge) {
            try await ChatTranscriptImageDecoder.decodeBase64(oversized)
        }
    }

    @Test
    func attachmentPresentationAcceptsInlineImagesAndKeepsRemoteLinksAsLinks() {
        var attachment = Attachment(data: nil, kind: "image", mimeType: "image/png", name: "sample", uri: "https://example.com/image.png")
        #expect(ChatMessageAttachmentPresentation.isImage(attachment))
        #expect(ChatMessageAttachmentPresentation.inlineImagePayload(from: attachment) == nil)
        attachment.uri = "data:image/png;base64,AAAA"
        #expect(ChatMessageAttachmentPresentation.inlineImagePayload(from: attachment) == "AAAA")
        attachment.uri = "data:image/png,unencoded"
        #expect(ChatMessageAttachmentPresentation.inlineImagePayload(from: attachment) == nil)
        attachment.data = "BBBB"
        #expect(ChatMessageAttachmentPresentation.inlineImagePayload(from: attachment) == "BBBB")
        #expect(ChatMessageAttachmentPresentation.displayName(attachment) == "sample")
    }

    @Test
    func removingPendingAttachmentCancelsInFlightWorkAndSuppressesErrors() async throws {
        final class Probe {
            var loadStarted: CheckedContinuation<Void, Never>?
            var releaseLoad: CheckedContinuation<String, any Error>?
            var finishedLoading: CheckedContinuation<Void, Never>?
            var wasCancelled = false
            var didFinish = false
        }

        let model = ComposerAttachmentsModel()
        var reportedErrors: [String] = []
        model.reportError = { reportedErrors.append($0) }
        let probe = Probe()

        let attachment = Attachment(data: nil, kind: "image", mimeType: "image/png", name: "sample.png", uri: nil)
        model.addSentImages([attachment]) { _ in
            defer {
                probe.didFinish = true
                probe.finishedLoading?.resume()
                probe.finishedLoading = nil
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    probe.releaseLoad = continuation
                    probe.loadStarted?.resume()
                    probe.loadStarted = nil
                }
            } onCancel: {
                Task { @MainActor in
                    probe.wasCancelled = true
                    probe.releaseLoad?.resume(throwing: CancellationError())
                    probe.releaseLoad = nil
                }
            }
        }

        if probe.releaseLoad == nil {
            await withCheckedContinuation { probe.loadStarted = $0 }
        }
        let pendingID = try #require(model.attachments.first?.id)
        model.remove(id: pendingID)

        // If remove(id:) did not cancel the task, fail the load so we observe
        // whether a removed attachment still surfaces an error.
        if let continuation = probe.releaseLoad {
            probe.releaseLoad = nil
            continuation.resume(throwing: RPCError("boom"))
        }
        if !probe.didFinish {
            await withCheckedContinuation { probe.finishedLoading = $0 }
        }
        // Let the enclosing Task run handleProcessingFailure after data() throws.
        await Task.yield()

        #expect(probe.wasCancelled)
        #expect(reportedErrors.isEmpty)
    }
}
