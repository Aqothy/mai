import SwiftUI

/// An agent's request in the chat: a permission to grant, a question or form
/// to answer, a link to open, or a plan to review. It shows the request's
/// message and details, and once answered, the action chosen and the answers.
struct ChatRequestRow: View {
    let request: ChatRequest

    @State private var model: ChatRequestModel

    init(request: ChatRequest, threadID: String, store: ThreadStore) {
        self.request = request
        _model = State(
            initialValue: ChatRequestModel(request: request.ask) { action, answers in
                try await store.respondToRequest(
                    threadID: threadID,
                    requestID: request.id,
                    actionID: action.id,
                    answers: answers
                )
            })
    }

    var body: some View {
        VStack(alignment: .leading) {
            if asksQuestions {
                Label("Question", systemImage: "questionmark.bubble")
                    .bold()
            } else {
                Label("Permission needed", systemImage: "hand.raised")
                    .bold()
            }

            if let messageText = model.messageText {
                Text(messageText)
                    .textSelection(.enabled)
            }

            if let details = request.ask.details {
                DisclosureGroup("Details") {
                    Text(ChatTimelineText.encoded(details.value))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            if request.isOpen {
                ChatRequestForm(model: model)
                    // Answered here or by another client; the agent hasn't
                    // taken the answer yet.
                    .disabled(request.actionID != nil)
            } else {
                ForEach(model.submittedAnswers(request.answers ?? [:])) { answer in
                    LabeledContent(answer.title, value: answer.answer)
                }
                Text(resolutionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(asksQuestions ? .blue.opacity(0.1) : .orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var asksQuestions: Bool {
        !(request.ask.questions ?? []).isEmpty || request.ask.url != nil
    }

    /// What was chosen, named after the action unless it accepted by
    /// submitting answers or opening a link; a request that ended without a
    /// choice was cancelled.
    private var resolutionLabel: String {
        guard let actionID = request.actionID,
            let action = request.ask.actions.first(where: { $0.id == actionID })
        else { return String(localized: "Cancelled") }
        if action.approvalDecision == .accept {
            if action.submit == true { return String(localized: "Answered") }
            if request.ask.url != nil { return String(localized: "Link opened") }
        }
        return action.label
    }
}
