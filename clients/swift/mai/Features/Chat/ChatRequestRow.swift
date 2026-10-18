import SwiftUI

/// An agent's request in the chat: a permission to grant, a question or form
/// to answer, a link to open, or a plan to review. It shows the request's
/// message and details, and once answered, the action chosen and the answers.
struct ChatRequestRow: View {
    let approval: Approval

    @State private var model: ChatRequestModel?

    init(approval: Approval, threadID: String, store: ThreadStore) {
        self.approval = approval
        _model = State(
            initialValue: approval.request.map { request in
                ChatRequestModel(request: request) { action, answers in
                    try await store.respondToApproval(
                        threadID: threadID,
                        requestID: approval.requestID,
                        actionID: action.id,
                        answers: answers
                    )
                }
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

            if let messageText = model?.messageText {
                Text(messageText)
                    .textSelection(.enabled)
            }

            if let args = approval.args {
                DisclosureGroup("Details") {
                    Text(ChatTimelineText.encoded(args.value))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            if approval.approvalStatus == .pending, let model {
                ChatRequestForm(model: model)
                    // Answered here or by another client; the agent hasn't
                    // taken the answer yet.
                    .disabled(approval.actionID != nil)
            } else {
                if let model {
                    ForEach(model.submittedAnswers(approval.answers ?? [:])) { answer in
                        LabeledContent(answer.title, value: answer.answer)
                    }
                }
                Text(resolutionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model?.errorMessage {
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
        guard let request = approval.request else { return false }
        return !(request.questions ?? []).isEmpty || request.url != nil
    }

    /// What the user chose, named after the action unless it accepted by
    /// submitting answers or opening a link; for a request that ended
    /// without a choice, what happened to it.
    private var resolutionLabel: String {
        if let actionID = approval.actionID,
            let action = approval.request?.actions.first(where: { $0.id == actionID })
        {
            if action.approvalDecision == .accept {
                if action.submit == true { return String(localized: "Answered") }
                if approval.request?.url != nil { return String(localized: "Link opened") }
            }
            return action.label
        }
        switch approval.decision.flatMap(MaidApprovalDecision.init(rawValue:)) {
        case .accept: return String(localized: "Accepted")
        case .acceptForSession: return String(localized: "Accepted for this session")
        case .decline: return String(localized: "Declined")
        case .cancel: return String(localized: "Cancelled")
        case nil: return String(localized: "Resolved")
        }
    }
}
