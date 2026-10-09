import SwiftUI

/// The answerable part of an agent's question: its fields or the link it asks
/// to open, and the decline, dismiss, and submit actions.
struct ChatQuestionForm: View {
    let model: ChatQuestionModel

    var body: some View {
        if model.request.url != nil {
            ChatQuestionLink(model: model)
        } else {
            ForEach(model.questions, id: \.id) { question in
                ChatQuestionField(question: question, model: model)
            }
        }
        ChatQuestionActions(model: model)
    }
}

/// Decline, dismiss, and submit (or, for a link, consent and open it).
private struct ChatQuestionActions: View {
    let model: ChatQuestionModel

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
                    Task { await model.submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
            }
        }
        .disabled(model.isResponding)
    }

    private func respond(_ decision: MaidApprovalDecision) async {
        await model.respond(decision)
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
