import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A downsampled transcript image. Core Graphics images are immutable after
/// creation, so this wrapper can safely cross from the detached decoder task
/// back to the main actor.
nonisolated struct ChatTranscriptImage: @unchecked Sendable {
    let cgImage: CGImage
}

nonisolated enum ChatTranscriptImageLoadingError: Error, Equatable {
    case encodedPayloadTooLarge
    case invalidBase64
    case imageDataTooLarge
    case invalidImage
    case imageDimensionsTooLarge
}

/// Decodes inline provider image blocks away from the main actor and only
/// materializes a display-sized bitmap. The byte and dimension checks protect
/// the chat timeline from malformed or unexpectedly large provider output.
nonisolated enum ChatTranscriptImageDecoder {
    nonisolated static let maximumImageBytes = 10 * 1024 * 1024
    // Accommodates current high-resolution phone photos while rejecting
    // implausibly large canvases before ImageIO attempts rasterization.
    nonisolated static let maximumPixelCount = 100_000_000
    nonisolated static let maximumSourceDimension = 32_768
    nonisolated static let maximumRenderedDimension = 2_048

    /// Allows MIME line wrapping while still bounding allocation before the
    /// base64 decoder runs.
    nonisolated static let maximumEncodedCharacterCount =
        ((maximumImageBytes + 2) / 3 * 4) + (maximumImageBytes / 8)

    nonisolated static func decodeBase64(
        _ payload: String
    ) async throws -> ChatTranscriptImage {
        let decodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try decodeBase64Synchronously(payload)
            try Task.checkCancellation()
            return image
        }
        return try await withTaskCancellationHandler {
            try await decodingTask.value
        } onCancel: {
            decodingTask.cancel()
        }
    }

    nonisolated private static func decodeBase64Synchronously(
        _ payload: String
    ) throws -> ChatTranscriptImage {
        guard payload.utf8.count <= maximumEncodedCharacterCount else {
            throw ChatTranscriptImageLoadingError.encodedPayloadTooLarge
        }

        guard
            let data = Data(
                base64Encoded: payload,
                options: .ignoreUnknownCharacters
            )
        else {
            throw ChatTranscriptImageLoadingError.invalidBase64
        }
        guard !data.isEmpty else {
            throw ChatTranscriptImageLoadingError.invalidImage
        }
        guard data.count <= maximumImageBytes else {
            throw ChatTranscriptImageLoadingError.imageDataTooLarge
        }
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0
        else {
            throw ChatTranscriptImageLoadingError.invalidImage
        }

        guard
            width <= maximumSourceDimension,
            height <= maximumSourceDimension,
            width <= maximumPixelCount / height
        else {
            throw ChatTranscriptImageLoadingError.imageDimensionsTooLarge
        }

        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumRenderedDimension,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ChatTranscriptImageLoadingError.invalidImage
        }
        return ChatTranscriptImage(cgImage: image)
    }
}

/// Presentation-only interpretation of provider attachments. ACP image blocks
/// carry raw base64, while data URLs are accepted defensively for providers
/// that surface that representation instead.
nonisolated enum ChatMessageAttachmentPresentation {
    static func isImage(_ attachment: Attachment) -> Bool {
        attachment.kind.lowercased() == "image"
            || attachment.mimeType?.lowercased().hasPrefix("image/") == true
    }

    static func displayName(_ attachment: Attachment) -> String {
        if let title = attachment.title, !title.isEmpty {
            return title
        }
        if let name = attachment.name, !name.isEmpty {
            return name
        }
        return attachment.kind.isEmpty ? "Attachment" : attachment.kind
    }

    static func inlineImagePayload(from attachment: Attachment) -> String? {
        if let data = attachment.data, !data.isEmpty {
            return base64Payload(from: data, acceptsRawBase64: true)
        }
        if let uri = attachment.uri, !uri.isEmpty {
            return base64Payload(from: uri, acceptsRawBase64: false)
        }
        return nil
    }

    private static func base64Payload(
        from value: String,
        acceptsRawBase64: Bool
    ) -> String? {
        guard value.prefix(5).lowercased() == "data:" else {
            return acceptsRawBase64 ? value : nil
        }
        guard
            let comma = value.firstIndex(of: ","),
            value.distance(from: value.startIndex, to: comma) <= 256,
            value[..<comma].lowercased().contains(";base64")
        else {
            return nil
        }
        let payload = value[value.index(after: comma)...]
        return payload.isEmpty ? nil : String(payload)
    }
}

/// Renders all transcript attachments without coupling message row variants to
/// image decoding. Image cards adapt into one or more columns as space allows;
/// non-image attachments retain their filename labels.
struct ChatMessageAttachmentsView: View {
    let attachments: [Attachment]

    var body: some View {
        let categorized = attachments.reduce(
            into: (images: [(attachment: Attachment, payload: String)](), others: [Attachment]())
        ) { result, attachment in
            if ChatMessageAttachmentPresentation.isImage(attachment),
                let payload = ChatMessageAttachmentPresentation.inlineImagePayload(from: attachment)
            {
                result.images.append((attachment, payload))
            } else {
                result.others.append(attachment)
            }
        }
        let imageAttachments = categorized.images
        let otherAttachments = categorized.others

        VStack(alignment: .leading, spacing: 8) {
            if !imageAttachments.isEmpty {
                if imageAttachments.count == 1 {
                    let image = imageAttachments[0]
                    ChatMessageImageAttachmentView(
                        attachment: image.attachment,
                        payload: image.payload
                    )
                    .frame(maxWidth: 480)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 140, maximum: 360),
                                spacing: 8,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(imageAttachments.indices, id: \.self) { index in
                            ChatMessageImageAttachmentView(
                                attachment: imageAttachments[index].attachment,
                                payload: imageAttachments[index].payload
                            )
                        }
                    }
                }
            }

            if !otherAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(otherAttachments.indices, id: \.self) { index in
                        ChatMessageOtherAttachmentView(
                            attachment: otherAttachments[index]
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMessageOtherAttachmentView: View {
    let attachment: Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let destination = ChatMarkdownLinkPolicy.url(for: attachment.uri) {
                Link(destination: destination) {
                    ChatMessageAttachmentLabel(attachment: attachment)
                }
            } else {
                ChatMessageAttachmentLabel(attachment: attachment)
            }

            if let description = attachment.description, !description.isEmpty {
                Text(description)
                    .lineLimit(2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChatMessageAttachmentLabel: View {
    let attachment: Attachment

    var body: some View {
        HStack {
            Label(
                ChatMessageAttachmentPresentation.displayName(attachment),
                systemImage: attachment.kind == "resource_link" ? "link" : "paperclip"
            )
            if let size = attachment.size, size > 0 {
                Text(Int64(size), format: .byteCount(style: .file))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ChatMessageImageAttachmentView: View {
    private enum Phase {
        case loading
        case loaded(ChatTranscriptImage)
        case failed
    }

    let attachment: Attachment
    let payload: String
    @State private var phase = Phase.loading

    var body: some View {
        let name = ChatMessageAttachmentPresentation.displayName(attachment)

        VStack(alignment: .leading, spacing: 4) {
            imageContent(name: name)
                // Images can share byte count, headers and trailers while
                // their pixels differ. Reuse must compare the whole payload.
                .task(id: payload) {
                    phase = .loading
                    do {
                        let image = try await ChatTranscriptImageDecoder.decodeBase64(
                            payload
                        )
                        try Task.checkCancellation()
                        phase = .loaded(image)
                    } catch is CancellationError {
                        return
                    } catch {
                        phase = .failed
                    }
                }

            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func imageContent(name: String) -> some View {
        switch phase {
        case .loading:
            ChatTranscriptImagePlaceholder(name: name)
        case .loaded(let image):
            Image(
                image.cgImage,
                scale: 1,
                orientation: .up,
                label: Text(name)
            )
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 420)
            .background(.secondary.opacity(0.06))
            .clipShape(.rect(cornerRadius: 12))
        case .failed:
            ChatTranscriptImageFallback(name: name)
        }
    }
}

private struct ChatTranscriptImagePlaceholder: View {
    let name: String

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            ProgressView()
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("Loading image")
    }
}

private struct ChatTranscriptImageFallback: View {
    let name: String

    var body: some View {
        VStack {
            Image(systemName: "photo")
                .imageScale(.large)
            Text("Image unavailable")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .aspectRatio(4 / 3, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.secondary.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("Image unavailable")
    }
}
