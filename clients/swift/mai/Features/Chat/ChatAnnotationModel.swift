import Foundation
import Observation
import SwiftUI

nonisolated struct ChatPendingAnnotation: Identifiable, Equatable, Sendable {
    let id: String
    let messageID: String?
    let quote: String
    let role: String?
    let note: String?

    @MainActor var promptAnnotation: PromptAnnotation {
        PromptAnnotation(
            id: id,
            messageID: messageID,
            note: note,
            quote: quote,
            role: role
        )
    }
}

nonisolated struct ChatAnnotationDraft: Identifiable, Equatable, Sendable {
    let id: String
    let messageID: String?
    let quote: String
    let role: String?
    var note: String
}

nonisolated enum ChatAnnotationFormatting {
    static func normalizedQuote(_ quote: String) -> String {
        quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedNote(_ note: String) -> String? {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? nil : note
    }

    static func summary(for annotation: ChatPendingAnnotation) -> String {
        let quote = annotation.quote
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let maximumLength = 72
        guard quote.count > maximumLength else { return quote }
        let end =
            quote.index(
                quote.startIndex,
                offsetBy: maximumLength,
                limitedBy: quote.endIndex
            ) ?? quote.endIndex
        return String(quote[..<end]) + "…"
    }
}

@Observable
final class ChatAnnotationModel {
    private(set) var annotations: [ChatPendingAnnotation] = []
    var editorDraft: ChatAnnotationDraft?

    func beginComment(
        quote: String,
        messageID: String?,
        role: String?
    ) {
        let quote = ChatAnnotationFormatting.normalizedQuote(quote)
        guard !quote.isEmpty else { return }
        editorDraft = ChatAnnotationDraft(
            id: UUID().uuidString,
            messageID: messageID,
            quote: quote,
            role: role,
            note: ""
        )
    }

    func addEditorDraft() {
        guard let editorDraft else { return }
        annotations.append(
            ChatPendingAnnotation(
                id: editorDraft.id,
                messageID: editorDraft.messageID,
                quote: editorDraft.quote,
                role: editorDraft.role,
                note: ChatAnnotationFormatting.normalizedNote(
                    editorDraft.note
                )
            )
        )
        self.editorDraft = nil
    }

    func cancelEditor() {
        editorDraft = nil
    }

    func remove(id: String) {
        annotations.removeAll { $0.id == id }
    }

    func removeSent(ids: Set<String>) {
        annotations.removeAll { ids.contains($0.id) }
    }

    func reset() {
        annotations.removeAll()
        editorDraft = nil
    }
}

struct ChatAnnotationContext {
    let messageID: String
    let role: String
    let model: ChatAnnotationModel
}

private struct ChatAnnotationContextKey: EnvironmentKey {
    static let defaultValue: ChatAnnotationContext? = nil
}

extension EnvironmentValues {
    var chatAnnotationContext: ChatAnnotationContext? {
        get { self[ChatAnnotationContextKey.self] }
        set { self[ChatAnnotationContextKey.self] = newValue }
    }
}

struct ChatAnnotationEditor: View {
    @Bindable var model: ChatAnnotationModel
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let draft = model.editorDraft {
                    VStack(alignment: .leading) {
                        Label("Selected text", systemImage: "quote.opening")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(draft.quote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(
                        .secondary.opacity(0.08),
                        in: .rect(cornerRadius: 14)
                    )

                    TextEditor(
                        text: Binding(
                            get: { model.editorDraft?.note ?? "" },
                            set: { model.editorDraft?.note = $0 }
                        )
                    )
                    .focused($isNoteFocused)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Comment")
                    .overlay(alignment: .topLeading) {
                        if draft.note.isEmpty {
                            Text("Add a comment for your next message")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Comment on Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        model.cancelEditor()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addEditorDraft()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            isNoteFocused = true
        }
    }
}

struct ChatComposerAnnotationStrip: View {
    let annotations: [ChatPendingAnnotation]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(annotations) { annotation in
                    HStack {
                        Label(
                            ChatAnnotationFormatting.summary(for: annotation),
                            systemImage: "text.quote"
                        )
                        .lineLimit(1)

                        Button("Remove annotation", systemImage: "xmark") {
                            remove(annotation.id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        .secondary.opacity(0.12),
                        in: .rect(cornerRadius: 12)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Annotation: \(ChatAnnotationFormatting.summary(for: annotation))"
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Pending annotations")
    }
}

struct ChatMessageAnnotationsView: View {
    let annotations: [PromptAnnotation]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(annotations, id: \.id) { annotation in
                VStack(alignment: .leading) {
                    Label("Quoted context", systemImage: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(annotation.quote)
                        .font(.callout)
                        .lineLimit(4)

                    if let note = annotation.note, !note.isEmpty {
                        Text(note)
                            .font(.callout)
                            .bold()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    .secondary.opacity(0.1),
                    in: .rect(cornerRadius: 12)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message annotations")
    }
}
