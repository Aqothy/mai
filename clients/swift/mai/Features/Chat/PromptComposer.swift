import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#endif

struct PromptComposer<LeadingControls: View, TrailingControls: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @Binding var text: String
    @State private var textSelection: TextSelection?
    @State private var appliedCursorRequestRevision = 0
    @State private var appliedCursorRequestModelID: ObjectIdentifier?

    let isEnabled: Bool
    let focusID: String?
    let canSend: Bool
    let isSending: Bool
    let isRunning: Bool
    let isStopping: Bool
    let attachments: [ChatPendingAttachment]
    let annotations: [ChatPendingAnnotation]
    let promptCompletion: PromptCompletionModel?
    let commands: [SlashCommand]
    let skills: [Skill]
    let submitLabel: String
    let send: () -> Void
    let stop: () -> Void
    let removeAttachment: (UUID) -> Void
    let removeAnnotation: (String) -> Void
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
        annotations: [ChatPendingAnnotation] = [],
        promptCompletion: PromptCompletionModel? = nil,
        commands: [SlashCommand] = [],
        skills: [Skill] = [],
        submitLabel: String,
        send: @escaping () -> Void,
        stop: @escaping () -> Void = {},
        removeAttachment: @escaping (UUID) -> Void = { _ in },
        removeAnnotation: @escaping (String) -> Void = { _ in },
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
        self.annotations = annotations
        self.promptCompletion = promptCompletion
        self.commands = commands
        self.skills = skills
        self.submitLabel = submitLabel
        self.send = send
        self.stop = stop
        self.removeAttachment = removeAttachment
        self.removeAnnotation = removeAnnotation
        self.leadingControls = leadingControls()
        self.trailingControls = trailingControls()
    }

    var body: some View {
        let catalogKey = PromptCompletionCatalogKey(
            commands: commands,
            skills: skills
        )
        let cursorRequest = promptCompletion?.cursorRequest
        let completionModelID = promptCompletion.map(ObjectIdentifier.init)
        let contentLayout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(alignment: .center))
            : AnyLayout(VStackLayout(alignment: .leading))

        contentLayout {
            if !attachments.isEmpty {
                ChatComposerAttachmentStrip(
                    attachments: attachments,
                    remove: removeAttachment
                )
            }

            if !annotations.isEmpty {
                ChatComposerAnnotationStrip(
                    annotations: annotations,
                    remove: removeAnnotation
                )
            }

            DraftPromptEditor(
                text: $text,
                selection: $textSelection,
                isEnabled: isEnabled,
                focusID: focusID,
                inputChanged: updatePromptCompletion,
                moveCompletionSelection: moveCompletionSelection,
                selectCompletion: selectCompletion,
                dismissCompletion: dismissCompletion
            )

            HStack {
                leadingControls

                Spacer()

                trailingControls

                Button {
                    if showsStop {
                        stop()
                    } else {
                        #if os(iOS)
                            // Dismiss the software keyboard before sending;
                            // macOS has no software keyboard, so nothing to do.
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
            .fixedSize(horizontal: verticalSizeClass == .compact, vertical: false)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .glassSurface(in: .rect(cornerRadius: 24), isShadowed: true)
        .frame(maxWidth: ChatContentMetrics.maximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 12)
        .onChange(of: catalogKey, initial: true) { _, _ in
            promptCompletion?.updateCatalog(commands: commands, skills: skills)
        }
        .onChange(of: cursorRequest, initial: true) { _, request in
            applyCursorRequest(request)
        }
        .onChange(of: completionModelID, initial: true) { oldID, newID in
            guard oldID != newID else { return }
            appliedCursorRequestRevision = 0
            appliedCursorRequestModelID = nil
            textSelection = nil
            promptCompletion?.updateCatalog(commands: commands, skills: skills)
            updatePromptCompletion(text: text, selection: nil)
            applyCursorRequest(promptCompletion?.cursorRequest)
        }
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

    private func updatePromptCompletion(
        text: String,
        selection: TextSelection?
    ) {
        guard let promptCompletion else { return }

        let cursorOffset: Int?
        if let request = promptCompletion.cursorRequest,
            request.revision != appliedCursorRequestRevision
                || appliedCursorRequestModelID != ObjectIdentifier(promptCompletion),
            request.text == text,
            request.cursorOffset >= 0,
            request.cursorOffset <= text.count
        {
            applyCursorRequest(request)
            cursorOffset = request.cursorOffset
        } else {
            cursorOffset = Self.cursorOffset(for: selection, in: text)
        }
        promptCompletion.update(text: text, cursorOffset: cursorOffset)
    }

    private func moveCompletionSelection(by offset: Int) -> Bool {
        promptCompletion?.moveSelection(by: offset) ?? false
    }

    private func selectCompletion() -> Bool {
        guard let promptCompletion,
            let edit = promptCompletion.editBySelectingCurrentMatch(in: text)
        else {
            return false
        }
        text = edit.text
        applyCursorRequest(promptCompletion.cursorRequest)
        return true
    }

    private func dismissCompletion() -> Bool {
        promptCompletion?.dismiss() ?? false
    }

    private func applyCursorRequest(_ request: PromptCompletionCursorRequest?) {
        guard let promptCompletion,
            let request,
            request.revision != appliedCursorRequestRevision
                || appliedCursorRequestModelID != ObjectIdentifier(promptCompletion),
            request.text == text,
            request.cursorOffset >= 0,
            request.cursorOffset <= text.count
        else { return }

        let insertionPoint = text.index(
            text.startIndex,
            offsetBy: request.cursorOffset
        )
        textSelection = TextSelection(insertionPoint: insertionPoint)
        appliedCursorRequestRevision = request.revision
        appliedCursorRequestModelID = ObjectIdentifier(promptCompletion)
    }

    private static func cursorOffset(
        for selection: TextSelection?,
        in text: String
    ) -> Int? {
        guard let selection else { return text.count }
        switch selection.indices {
        case .selection(let range):
            guard range.isEmpty else { return nil }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        case .multiSelection(_):
            return nil
        @unknown default:
            return nil
        }
    }
}

private struct DraftPromptEditor: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @Binding var text: String
    @Binding var selection: TextSelection?

    let isEnabled: Bool
    let focusID: String?
    let inputChanged: (String, TextSelection?) -> Void
    let moveCompletionSelection: (Int) -> Bool
    let selectCompletion: () -> Bool
    let dismissCompletion: () -> Bool

    @FocusState private var isFocused: Bool

    private var maximumLineCount: Int {
        // Keep the controls inside the keyboard safe area on landscape
        // phones. The vertical text field scrolls through the full draft.
        verticalSizeClass == .compact ? 1 : 6
    }

    private var minimumLineCount: Int {
        min(text.lazy.filter(\.isNewline).count + 1, maximumLineCount)
    }

    var body: some View {
        let input = DraftPromptInput(text: text, selection: selection)

        TextField(
            "Ask anything",
            text: $text,
            selection: $selection,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(minimumLineCount...maximumLineCount)
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
                moveCompletionSelection(1)
            {
                return .handled
            }
            if keyPress.key == .upArrow,
                moveCompletionSelection(-1)
            {
                return .handled
            }
            if keyPress.key == .escape,
                dismissCompletion()
            {
                return .handled
            }
            if keyPress.key == .return,
                selectCompletion()
            {
                return .handled
            }
            if keyPress.key == .tab,
                selectCompletion()
            {
                return .handled
            }
            return .ignored
        }
        .onChange(of: focusID, initial: true) { _, focusID in
            // Only a draft prompt auto-focuses. The composer keeps one
            // identity across the draft-to-thread transition, so focus
            // acquired in the draft must be released when a thread opens.
            isFocused = focusID != nil
            selection = nil
        }
        .onChange(of: input, initial: true) { _, input in
            inputChanged(input.text, input.selection)
        }
    }
}

private struct DraftPromptInput: Equatable {
    let text: String
    let selection: TextSelection?
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
    @State private var selectedPhotos: [PhotosPickerItem] = []

    // The camera entry point is iOS-only; macOS has no UIImagePickerController
    // equivalent here, so the menu simply omits the item.
    #if os(iOS)
        @State private var isCameraPresented = false
    #endif

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
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

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
                SlashCommand(
                    description: nil,
                    hasInput: false,
                    inputHint: nil,
                    name: "compact"
                ),
                SlashCommand(
                    description: nil,
                    hasInput: true,
                    inputHint: "instructions",
                    name: "review"
                ),
            ],
            addImages: { _ in },
            addPhotos: { _ in },
            addCameraImage: { _ in },
            insertCommand: { _ in },
            showError: { _ in }
        )
        .padding()
    }

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
                        image: chatPreviewSymbolImage("photo.fill")
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
