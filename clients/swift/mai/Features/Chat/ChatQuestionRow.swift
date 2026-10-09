import SwiftUI

/// An agent's question: a form to fill in, or a link it asks to open. The user
/// can submit, decline, or dismiss it without choosing.
struct ChatQuestionRow: View {
    let approval: Approval

    @State private var model: ChatQuestionModel

    init(approval: Approval, request: UserInputRequest, threadID: String, store: ThreadStore) {
        self.approval = approval
        _model = State(
            initialValue: ChatQuestionModel(request: request) { decision, answers in
                try await store.respondToApproval(
                    threadID: threadID,
                    requestID: approval.requestID,
                    decision: decision,
                    optionID: nil,
                    answers: answers
                )
            })
    }

    var body: some View {
        VStack(alignment: .leading) {
            Label("Question", systemImage: "questionmark.bubble")
                .bold()
            Text(model.messageText)
                .textSelection(.enabled)

            if approval.approvalStatus == .pending {
                ChatQuestionForm(model: model)
            } else {
                ForEach(model.submittedAnswers(approval.answers ?? [:])) { answer in
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
        .background(.blue.opacity(0.1), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolutionLabel: String {
        switch approval.decision.flatMap(MaidApprovalDecision.init(rawValue:)) {
        case .accept: model.request.url == nil ? "Answered" : "Link opened"
        case .decline: "Declined"
        case .cancel, .acceptForSession: "Dismissed"
        case nil: "Resolved"
        }
    }

}
