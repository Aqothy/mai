import SwiftUI

/// The answerable part of an agent's request: its questions or the link it
/// asks to open, and the actions that answer it.
struct ChatRequestForm: View {
    let model: ChatRequestModel

    var body: some View {
        if model.request.url != nil {
            ChatRequestLink(model: model)
        } else {
            ForEach(model.questions, id: \.id) { question in
                ChatQuestionField(question: question, model: model)
            }
        }
        ChatRequestActions(model: model)
    }
}

/// One button per action, in the agent's order. Accepting a link request
/// opens the link once the agent has the answer.
private struct ChatRequestActions: View {
    let model: ChatRequestModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Approvals can offer several lasting choices; let them wrap.
        ViewThatFits(in: .horizontal) {
            HStack { buttons }
            VStack(alignment: .leading) { buttons }
        }
        .disabled(model.isResponding)
    }

    private var buttons: some View {
        ForEach(model.request.actions, id: \.id) { action in
            ChatRequestActionButton(action: action, model: model, opensLink: opensLink(action)) {
                Task {
                    if await model.choose(action), opensLink(action), let url = model.url {
                        openURL(url)
                    }
                }
            }
        }
    }

    private func opensLink(_ action: RequestAction) -> Bool {
        model.request.url != nil && action.approvalDecision == .accept
    }
}

private struct ChatRequestActionButton: View {
    let action: RequestAction
    let model: ChatRequestModel
    let opensLink: Bool
    let choose: () -> Void

    var body: some View {
        if opensLink {
            Button(action.label, systemImage: "safari", action: choose)
                .buttonStyle(.borderedProminent)
                .disabled(model.url == nil || !model.canChoose(action))
        } else if action.submit == true {
            Button(action.label, action: choose)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canChoose(action))
        } else {
            Button(action.label, role: action.approvalDecision == .decline ? .destructive : nil, action: choose)
                .disabled(!model.canChoose(action))
        }
    }
}

/// Shows the full link a URL request asks to open, with its host
/// highlighted, before the user consents.
private struct ChatRequestLink: View {
    let model: ChatRequestModel

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

extension RequestAction {
    var approvalDecision: MaidApprovalDecision? { MaidApprovalDecision(rawValue: decision) }
}
