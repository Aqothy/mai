import CoreTransferable
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

struct ChatPendingAttachment: Identifiable {
    let id: UUID
    let name: String
    var thumbnail: ChatComposerThumbnail?
    var attachment: Attachment?

    init(
        id: UUID = UUID(),
        name: String,
        thumbnail: ChatComposerThumbnail? = nil
    ) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
    }

    var isProcessing: Bool {
        attachment == nil
    }

    mutating func finish(with loaded: ChatLoadedImageAttachment) {
        if let loadedThumbnail = loaded.thumbnail {
            thumbnail = loadedThumbnail
        }
        attachment = Attachment(
            data: loaded.data,
            kind: "image",
            mimeType: loaded.mimeType,
            name: loaded.name,
            uri: nil
        )
    }
}

/// The composer's pending-attachment list and its async image-encoding
/// pipeline, shared by the draft and thread prompt models.
@Observable
final class ComposerAttachmentsModel {
    private(set) var attachments: [ChatPendingAttachment] = []

    /// Draft composers gate on the selected provider's capabilities; thread
    /// composers leave the default because the add menu is hidden instead.
    @ObservationIgnored var canAttachImages: () -> Bool = { true }
    @ObservationIgnored var reportError: (String) -> Void = { _ in }

    private static let limitMessage =
        "You can attach up to \(ChatAttachmentLoader.maximumAttachmentCount) images per message."
    private static let unsupportedMessage =
        "The selected provider does not support image attachments."

    func addImages(from urls: [URL]) async {
        guard let availableCount = availableCountForAddingImages() else { return }

        if urls.count > availableCount {
            reportError(Self.limitMessage)
        }

        for url in urls.prefix(availableCount) {
            let id = UUID()
            let name = url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
            attachments.append(ChatPendingAttachment(id: id, name: name))
            Task {
                await processFileAttachment(id: id, url: url)
            }
        }
    }

    func addPhotos(_ photos: [PhotosPickerItem]) {
        guard let availableCount = availableCountForAddingImages() else { return }

        if photos.count > availableCount {
            reportError(Self.limitMessage)
        }

        for photo in photos.prefix(availableCount) {
            let id = UUID()
            attachments.append(ChatPendingAttachment(id: id, name: "Photo"))
            Task {
                await processPhotoAttachment(id: id, photo: photo)
            }
        }
    }

    func addCameraImage(_ thumbnail: ChatComposerThumbnail) {
        guard ensureImagesAllowed() else { return }
        guard attachments.count < ChatAttachmentLoader.maximumAttachmentCount else {
            reportError(Self.limitMessage)
            return
        }

        let id = UUID()
        let name = "camera-\(UUID().uuidString).jpg"
        attachments.append(
            ChatPendingAttachment(id: id, name: "Camera photo", thumbnail: thumbnail)
        )
        Task {
            await processCameraAttachment(id: id, thumbnail: thumbnail, name: name)
        }
    }

    func remove(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func remove(ids: Set<UUID>) {
        attachments.removeAll { ids.contains($0.id) }
    }

    private func ensureImagesAllowed() -> Bool {
        guard canAttachImages() else {
            reportError(Self.unsupportedMessage)
            return false
        }
        return true
    }

    private func availableCountForAddingImages() -> Int? {
        guard ensureImagesAllowed() else { return nil }
        let availableCount = max(
            0,
            ChatAttachmentLoader.maximumAttachmentCount - attachments.count
        )
        guard availableCount > 0 else {
            reportError(Self.limitMessage)
            return nil
        }
        return availableCount
    }

    private func processFileAttachment(id: UUID, url: URL) async {
        do {
            let thumbnail = try await ChatAttachmentLoader.loadThumbnail(from: url)
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[index].thumbnail = thumbnail

            let loaded = try await ChatAttachmentLoader.prepareImageUpload(from: url)
            finishAttachment(id: id, with: loaded)
        } catch {
            handleProcessingFailure(error, attachmentID: id)
        }
    }

    private func processPhotoAttachment(id: UUID, photo: PhotosPickerItem) async {
        do {
            let transfer = try await ChatAttachmentLoader.loadPhotoTransfer(from: photo)
            defer { transfer.removeTransferredFile() }

            let thumbnail = try await ChatAttachmentLoader.loadThumbnail(from: transfer.fileURL)
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[index].thumbnail = thumbnail

            let loaded = try await ChatAttachmentLoader.prepareImageUpload(
                from: transfer.fileURL
            )
            finishAttachment(id: id, with: loaded)
        } catch {
            handleProcessingFailure(error, attachmentID: id)
        }
    }

    private func processCameraAttachment(
        id: UUID,
        thumbnail: ChatComposerThumbnail,
        name: String
    ) async {
        do {
            let loaded = try await ChatAttachmentLoader.loadCameraImage(thumbnail, name: name)
            finishAttachment(id: id, with: loaded)
        } catch {
            handleProcessingFailure(error, attachmentID: id)
        }
    }

    private func finishAttachment(id: UUID, with loaded: ChatLoadedImageAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].finish(with: loaded)
    }

    private func handleProcessingFailure(_ error: Error, attachmentID: UUID) {
        attachments.removeAll { $0.id == attachmentID }
        if !(error is CancellationError) {
            reportError(error.localizedDescription)
        }
    }
}

struct ChatComposerAttachmentStrip: View {
    let attachments: [ChatPendingAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { pending in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = pending.thumbnail {
                                Image(platformImage: thumbnail.image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.12)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .blur(radius: pending.isProcessing ? 4 : 0)
                        .clipShape(.rect(cornerRadius: 14))
                        // The thumbnail is its own element so the remove
                        // button stays separately reachable in VoiceOver.
                        .accessibilityElement()
                        .accessibilityLabel(pending.name)
                        .accessibilityValue(pending.isProcessing ? "Processing" : "Ready")

                        Button("Remove attachment", systemImage: "xmark") {
                            remove(pending.id)
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.72), in: .circle)
                        .contentShape(.circle)
                        .buttonStyle(.plain)
                        .padding(5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }
}

final class ChatComposerThumbnail: @unchecked Sendable {
    nonisolated let image: PlatformImage

    nonisolated init(image: PlatformImage) {
        self.image = image
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

struct ChatPhotoTransfer: Transferable, Sendable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let directory = URL.temporaryDirectory.appending(
                path: "mai-composer-photo-imports",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let pathExtension = received.file.pathExtension
            var destination = directory.appending(path: UUID().uuidString)
            if !pathExtension.isEmpty {
                destination.appendPathExtension(pathExtension)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ChatPhotoTransfer(fileURL: destination)
        }
    }

    func removeTransferredFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum ChatAttachmentLoader {
    nonisolated static let maximumAttachmentCount = 8
    nonisolated static let maximumImageBytes = 10 * 1024 * 1024

    nonisolated static func loadPhotoTransfer(
        from item: PhotosPickerItem
    ) async throws -> ChatPhotoTransfer {
        guard let transfer = try await item.loadTransferable(type: ChatPhotoTransfer.self) else {
            throw ChatAttachmentLoadingError.photoTransferFailed
        }
        return transfer
    }

    nonisolated static func loadThumbnail(from url: URL) async throws -> ChatComposerThumbnail {
        try await Task.detached(priority: .userInitiated) {
            try withSecurityScope(for: url) {
                guard
                    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 320,
                        ] as CFDictionary
                    )
                else {
                    throw ChatAttachmentLoadingError.invalidImage(name: url.lastPathComponent)
                }
                #if canImport(UIKit)
                let platformImage = UIImage(cgImage: image)
                #else
                let platformImage = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                #endif
                return ChatComposerThumbnail(image: platformImage)
            }
        }.value
    }

    nonisolated static func loadImage(from url: URL) async throws -> ChatLoadedImageAttachment {
        try await Task.detached(priority: .userInitiated) {
            try withSecurityScope(for: url) {
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let contentType =
                    values.contentType
                    ?? UTType(filenameExtension: url.pathExtension)

                guard contentType?.conforms(to: .image) == true else {
                    throw ChatAttachmentLoadingError.unsupportedFile(name: url.lastPathComponent)
                }

                if let byteCount = values.fileSize,
                   byteCount > maximumImageBytes {
                    throw ChatAttachmentLoadingError.imageTooLarge(name: url.lastPathComponent)
                }

                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard !data.isEmpty else {
                    throw ChatAttachmentLoadingError.emptyFile(name: url.lastPathComponent)
                }
                guard data.count <= maximumImageBytes else {
                    throw ChatAttachmentLoadingError.imageTooLarge(name: url.lastPathComponent)
                }

                return ChatLoadedImageAttachment(
                    data: data.base64EncodedString(),
                    mimeType: contentType?.preferredMIMEType ?? "application/octet-stream",
                    name: url.lastPathComponent.isEmpty ? "image" : url.lastPathComponent
                )
            }
        }.value
    }

    nonisolated static func prepareImageUpload(
        from url: URL
    ) async throws -> ChatLoadedImageAttachment {
        try await ChatAttachmentEncodingGate.shared.loadImage(from: url)
    }

    nonisolated static func loadCameraImage(
        _ thumbnail: ChatComposerThumbnail,
        name: String
    ) async throws -> ChatLoadedImageAttachment {
        try await Task.detached(priority: .userInitiated) {
            guard let data = jpegData(from: thumbnail.image) else {
                throw ChatAttachmentLoadingError.invalidImage(name: name)
            }
            guard !data.isEmpty else {
                throw ChatAttachmentLoadingError.emptyFile(name: name)
            }
            guard data.count <= maximumImageBytes else {
                throw ChatAttachmentLoadingError.imageTooLarge(name: name)
            }
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                    ] as CFDictionary
                )
            else {
                throw ChatAttachmentLoadingError.invalidImage(name: name)
            }
            #if canImport(UIKit)
            let platformImage = UIImage(cgImage: image)
            #else
            let platformImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            #endif
            return ChatLoadedImageAttachment(
                data: data.base64EncodedString(),
                mimeType: "image/jpeg",
                name: name,
                thumbnail: ChatComposerThumbnail(image: platformImage)
            )
        }.value
    }

    nonisolated private static func jpegData(from image: PlatformImage) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: 0.92)
        #else
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        #endif
    }

    nonisolated private static func withSecurityScope<Value>(
        for url: URL,
        operation: () throws -> Value
    ) throws -> Value {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }
}

private actor ChatAttachmentEncodingGate {
    static let shared = ChatAttachmentEncodingGate()

    private var isEncoding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func loadImage(from url: URL) async throws -> ChatLoadedImageAttachment {
        await acquire()
        defer { release() }
        return try await ChatAttachmentLoader.loadImage(from: url)
    }

    private func acquire() async {
        guard isEncoding else {
            isEncoding = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isEncoding = false
            return
        }
        waiters.removeFirst().resume()
    }
}

struct ChatLoadedImageAttachment: Sendable {
    let data: String
    let mimeType: String
    let name: String
    let thumbnail: ChatComposerThumbnail?

    nonisolated init(
        data: String,
        mimeType: String,
        name: String,
        thumbnail: ChatComposerThumbnail? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.name = name
        self.thumbnail = thumbnail
    }
}

private enum ChatAttachmentLoadingError: LocalizedError {
    case emptyFile(name: String)
    case imageTooLarge(name: String)
    case invalidImage(name: String)
    case photoTransferFailed
    case unsupportedFile(name: String)

    var errorDescription: String? {
        switch self {
        case .emptyFile(let name):
            "'\(name)' is empty."
        case .imageTooLarge(let name):
            "'\(name)' exceeds the 10 MB image limit."
        case .invalidImage(let name):
            "'\(name)' could not be read as an image."
        case .photoTransferFailed:
            "The selected photo could not be loaded."
        case .unsupportedFile(let name):
            "'\(name)' is not a supported image."
        }
    }
}

#if DEBUG && canImport(UIKit)
#Preview("Composer Attachments") {
    ChatComposerAttachmentStrip(
        attachments: [
            ChatPendingAttachment(
                name: "Example photo",
                thumbnail: ChatComposerThumbnail(
                    image: UIImage(systemName: "photo.fill") ?? UIImage()
                )
            )
        ],
        remove: { _ in }
    )
    .padding()
    .background(.background)
}
#endif
