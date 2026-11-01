import SwiftUI

extension ProviderQuestion: Identifiable {
    public var id: String { requestID }
}

/// A question the agent asks while the user signs in, before any chat exists
/// to show it in. Answering, declining, or dismissing it lets sign-in go on.
struct ProviderQuestionSheet: View {
    @State private var model: ChatRequestModel

    init(question: ProviderQuestion, account: ProviderAccountModel) {
        _model = State(
            initialValue: ChatRequestModel(request: question.request) { action, answers in
                try await account.answerQuestion(action, answers: answers)
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let messageText = model.messageText {
                    Section {
                        Text(messageText)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    ChatRequestForm(model: model)
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sign In")
            .inlineNavigationBarTitle()
        }
        // Dismissing must answer the agent, which waits for a response.
        .interactiveDismissDisabled()
    }
}
