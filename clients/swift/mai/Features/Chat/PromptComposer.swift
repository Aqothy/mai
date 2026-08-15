import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#endif

struct PromptComposer<LeadingControls: View, TrailingControls: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var text: String

    let isEnabled: Bool
    let focusID: String?
    let canSend: Bool
    let isSending: Bool
    let isRunning: Bool
    let isStopping: Bool
    let attachments: [ChatPendingAttachment]
    let workspaceFilePicker: WorkspaceFilePickerModel?
    let submitLabel: String
    let send: () -> Void
    let stop: () -> Void
    let removeAttachment: (UUID) -> Void
    let leadingControls: LeadingControls
    let trailingControls: TrailingControls

    init(
        text: Binding<String>,
        isEnabled: Bool,
        focusID: String?,
        canSend: Bool,
        isSending: Bool,
        isRunning: Bool = false,
        isStopping: Bool = false,
        attachments: [ChatPendingAttachment] = [],
        workspaceFilePicker: WorkspaceFilePickerModel? = nil,
        submitLabel: String,
        send: @escaping () -> Void,
        stop: @escaping () -> Void = {},
        removeAttachment: @escaping (UUID) -> Void = { _ in },
        @ViewBuilder leadingControls: () -> LeadingControls,
        @ViewBuilder trailingControls: () -> TrailingControls
    ) {
        _text = text
        self.isEnabled = isEnabled
        self.focusID = focusID
        self.canSend = canSend
        self.isSending = isSending
        self.isRunning = isRunning
        self.isStopping = isStopping
        self.attachments = attachments
        self.workspaceFilePicker = workspaceFilePicker
        self.submitLabel = submitLabel
        self.send = send
        self.stop = stop
        self.removeAttachment = removeAttachment
        self.leadingControls = leadingControls()
        self.trailingControls = trailingControls()
    }

    var body: some View {
        VStack(alignment: .leading) {
            if !attachments.isEmpty {
                ChatComposerAttachmentStrip(
                    attachments: attachments,
                    remove: removeAttachment
                )
            }

            DraftPromptEditor(
                text: $text,
                isEnabled: isEnabled,
                focusID: focusID,
                canSend: canSend,
                send: send,
                textChanged: updateWorkspaceFilePicker,
                moveWorkspaceFileSelection: moveWorkspaceFileSelection,
                selectWorkspaceFile: selectWorkspaceFile,
                dismissWorkspaceFilePicker: dismissWorkspaceFilePicker
            )

            HStack {
                leadingControls

                Spacer()

                trailingControls

                Button {
                    if showsStop {
                        stop()
                    } else {
                        #if canImport(UIKit)
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil,
                                from: nil,
                                for: nil
                            )
                        #endif
                        send()
                    }
                } label: {
                    Group {
                        if isSending || isStopping {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(
                                showsStop ? "Stop generation" : submitLabel,
                                systemImage: showsStop ? "stop.fill" : "arrow.up"
                            )
                            .labelStyle(.iconOnly)
                        }
                    }
                    .font(.body.bold())
                    .frame(width: 36, height: 36)
                    .background(sendButtonBackground, in: .circle)
                    .foregroundStyle(sendButtonForeground)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(showsStop ? isStopping : !canSend)
            }
            .frame(height: 36)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .glassSurface(in: .rect(cornerRadius: 24), isShadowed: true)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// While a turn is running the button stops it, unless there is a draft to
    /// send — sending mid-turn queues the prompt instead.
    private var showsStop: Bool {
        isRunning && !canSend
    }

    // High-contrast fill that inverts with the color scheme, so the button
    // reads against the composer surface in both appearances.
    private var sendButtonBackground: Color {
        guard isRunning || canSend else { return .secondary.opacity(0.18) }
        return colorScheme == .dark ? .white : .black
    }

    private var sendButtonForeground: Color {
        guard isRunning || canSend else { return .secondary }
        return colorScheme == .dark ? .black : .white
    }

    private func updateWorkspaceFilePicker(oldText: String, newText: String) {
        workspaceFilePicker?.textDidChange(from: oldText, to: newText)
    }

    private func moveWorkspaceFileSelection(by offset: Int) -> Bool {
        workspaceFilePicker?.moveSelection(by: offset) ?? false
    }

    private func selectWorkspaceFile() -> Bool {
        guard let updatedText = workspaceFilePicker?.textBySelectingCurrentMatch(
            in: text
        ) else { return false }
        text = updatedText
        return true
    }

    private func dismissWorkspaceFilePicker() -> Bool {
        workspaceFilePicker?.dismiss() ?? false
    }
}

private struct DraftPromptEditor: View {
    @Binding var text: String

    let isEnabled: Bool
    let focusID: String?
    let canSend: Bool
    let send: () -> Void
    let textChanged: (String, String) -> Void
    let moveWorkspaceFileSelection: (Int) -> Bool
    let selectWorkspaceFile: () -> Bool
    let dismissWorkspaceFilePicker: () -> Bool

    @FocusState private var isFocused: Bool

    private var minimumLineCount: Int {
        min(text.lazy.filter(\.isNewline).count + 1, 6)
    }

    var body: some View {
        TextField(
            "Ask anything",
            text: $text,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(minimumLineCount...6)
        .focused($isFocused)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background {
            Button {
                isFocused = true
            } label: {
                Color.clear
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Prompt")
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .downArrow,
               moveWorkspaceFileSelection(1) {
                return .handled
            }
            if keyPress.key == .upArrow,
               moveWorkspaceFileSelection(-1) {
                return .handled
            }
            if keyPress.key == .escape,
               dismissWorkspaceFilePicker() {
                return .handled
            }
            if keyPress.key == .return,
               selectWorkspaceFile() {
                return .handled
            }
            #if os(macOS)
                guard keyPress.key == .return,
                    !keyPress.modifiers.contains(.shift),
                    canSend
                else {
                    return .ignored
                }
                isFocused = false
                send()
                return .handled
            #else
                return .ignored
            #endif
        }
        .onChange(of: focusID, initial: true) { _, focusID in
            // Only a draft prompt auto-focuses. The composer keeps one
            // identity across the draft-to-thread transition, so focus
            // acquired in the draft must be released when a thread opens.
            isFocused = focusID != nil
        }
        .onChange(of: text) { oldText, newText in
            textChanged(oldText, newText)
        }
    }
}

struct ComposerAddMenu: View {
    let isImageAttachmentAvailable: Bool
    let isImageAttachmentDisabled: Bool
    let maximumImageSelectionCount: Int
    let commands: [SlashCommand]
    var addWorkspaceFile: (() -> Void)? = nil
    let addImages: ([URL]) async -> Void
    let addPhotos: ([PhotosPickerItem]) -> Void
    let addCameraImage: (ChatComposerThumbnail) -> Void
    let insertCommand: (SlashCommand) -> Void
    let showError: (Error) -> Void

    @State private var isImporterPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var isCameraPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            if let addWorkspaceFile {
                Button("Workspace File", systemImage: "at") {
                    addWorkspaceFile()
                }
            }

            if isImageAttachmentAvailable {
                Button("Image Files", systemImage: "folder") {
                    isImporterPresented = true
                }
                .disabled(isImageAttachmentDisabled)

                Button("Photos", systemImage: "photo.on.rectangle") {
                    isPhotosPickerPresented = true
                }
                .disabled(isImageAttachmentDisabled)

                #if os(iOS)
                    Button("Camera", systemImage: "camera") {
                        isCameraPresented = true
                    }
                    .disabled(
                        isImageAttachmentDisabled
                            || !UIImagePickerController.isSourceTypeAvailable(.camera)
                    )
                #endif
            }

            if !commands.isEmpty {
                Section("Commands") {
                    ForEach(commands, id: \.name) { command in
                        Button("/\(command.name)", systemImage: "slash.circle") {
                            insertCommand(command)
                        }
                    }
                }
            }

            if addWorkspaceFile == nil, !isImageAttachmentAvailable, commands.isEmpty {
                Button("No actions available", systemImage: "ellipsis") {}
                    .disabled(true)
            }
        } label: {
            Label("Add", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await addImages(urls)
                }
            case .failure(let error):
                showError(error)
            }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: maximumImageSelectionCount,
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            selectedPhotos = []
            addPhotos(photos)
        }
        #if os(iOS)
            .fullScreenCover(isPresented: $isCameraPresented) {
                ComposerCameraPicker {
                    isCameraPresented = false
                    addCameraImage(ChatComposerThumbnail(image: $0))
                } cancel: {
                    isCameraPresented = false
                }
                .ignoresSafeArea()
            }
        #endif
    }
}

#if os(iOS)
    private struct ComposerCameraPicker: UIViewControllerRepresentable {
        let capture: (UIImage) -> Void
        let cancel: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let controller = UIImagePickerController()
            controller.sourceType = .camera
            controller.mediaTypes = [UTType.image.identifier]
            controller.cameraCaptureMode = .photo
            controller.delegate = context.coordinator
            return controller
        }

        func updateUIViewController(
            _ uiViewController: UIImagePickerController,
            context: Context
        ) {
            context.coordinator.parent = self
        }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate,
            UINavigationControllerDelegate
        {
            var parent: ComposerCameraPicker

            init(parent: ComposerCameraPicker) {
                self.parent = parent
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                guard let image = info[.originalImage] as? UIImage else {
                    parent.cancel()
                    return
                }
                parent.capture(image)
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                parent.cancel()
            }
        }
    }
#endif

#if DEBUG
    #Preview("Composer Add Menu") {
        ComposerAddMenu(
            isImageAttachmentAvailable: true,
            isImageAttachmentDisabled: false,
            maximumImageSelectionCount: 8,
            commands: [
                SlashCommand(description: nil, hasInput: false, name: "compact"),
                SlashCommand(description: nil, hasInput: true, name: "review"),
            ],
            addImages: { _ in },
            addPhotos: { _ in },
            addCameraImage: { _ in },
            insertCommand: { _ in },
            showError: { _ in }
        )
        .padding()
    }

    #if canImport(UIKit)
        #Preview("Composer With Attachment") {
            @Previewable @State var text = ""

            PromptComposer(
                text: $text,
                isEnabled: true,
                focusID: nil,
                canSend: false,
                isSending: false,
                attachments: [
                    ChatPendingAttachment(
                        name: "Example photo",
                        thumbnail: ChatComposerThumbnail(
                            image: UIImage(systemName: "photo.fill") ?? UIImage()
                        )
                    )
                ],
                submitLabel: "Send",
                send: {}
            ) {
                ComposerAddMenu(
                    isImageAttachmentAvailable: true,
                    isImageAttachmentDisabled: false,
                    maximumImageSelectionCount: 7,
                    commands: [],
                    addImages: { _ in },
                    addPhotos: { _ in },
                    addCameraImage: { _ in },
                    insertCommand: { _ in },
                    showError: { _ in }
                )
            } trailingControls: {
                Text("Model")
            }
            .padding()
        }
    #endif
#endif
