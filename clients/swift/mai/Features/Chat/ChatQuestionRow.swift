import SwiftUI

/// An agent's question: a form to fill in, or a link it asks to open. The user
/// can submit, decline, or dismiss it without choosing.
struct ChatQuestionRow: View {
    let approval: Approval
    let threadID: String
    let store: ThreadStore

    @State private var model: ChatQuestionModel

    init(approval: Approval, request: UserInputRequest, threadID: String, store: ThreadStore) {
        self.approval = approval
        self.threadID = threadID
        self.store = store
        _model = State(initialValue: ChatQuestionModel(request: request))
    }

    var body: some View {
        VStack(alignment: .leading) {
            Label("Question", systemImage: "questionmark.bubble")
                .bold()
            Text(model.request.message)
                .textSelection(.enabled)

            if approval.approvalStatus == .pending {
                if model.request.url != nil {
                    ChatQuestionLink(model: model)
                } else {
                    ForEach(model.questions, id: \.id) { question in
                        ChatQuestionField(question: question, model: model)
                    }
                }
                ChatQuestionActions(model: model, requestID: approval.requestID, threadID: threadID, store: store)
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

/// Decline, dismiss, and submit (or, for a link, consent and open it).
private struct ChatQuestionActions: View {
    let model: ChatQuestionModel
    let requestID: String
    let threadID: String
    let store: ThreadStore

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            Button("Decline", role: .destructive) {
                Task { await respond(.decline) }
            }
            Button("Dismiss") {
                Task { await respond(.cancel) }
            }
            if let url = model.url {
                Button("Open Link", systemImage: "safari") {
                    Task {
                        await respond(.accept)
                        if model.errorMessage == nil {
                            openURL(url)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if model.request.url == nil {
                Button("Submit") {
                    Task { await model.submit(threadID: threadID, requestID: requestID, store: store) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
            }
        }
        .disabled(model.isResponding)
    }

    private func respond(_ decision: MaidApprovalDecision) async {
        await model.respond(decision, threadID: threadID, requestID: requestID, store: store)
    }
}

/// Shows the full link a URL-mode question asks to open, with its host
/// highlighted, before the user consents.
private struct ChatQuestionLink: View {
    let model: ChatQuestionModel

    var body: some View {
        if let url = model.url {
            VStack(alignment: .leading) {
                Text(url.host() ?? "")
                    .bold()
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.hasSuspiciousHost {
                    Label(
                        "This address uses international characters that can imitate another site.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        } else {
            Label("The agent sent a link that can't be opened.", systemImage: "link.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
