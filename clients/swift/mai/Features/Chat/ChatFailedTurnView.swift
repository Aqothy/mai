import SwiftUI

/// A failed turn's error. The agent's session keeps the message and what it
/// did before failing, so what comes next is the person's to write.
struct ChatFailedTurnView: View {
    let model: ChatPromptModel

    @State private var signIn: ChatSignInTarget?

    var body: some View {
        HStack {
            Label(
                model.failedTurnError ?? "The response failed.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Spacer()

            if let providerID = model.signInProviderID {
                Button("Sign In", systemImage: "person.crop.circle.badge.exclamationmark") {
                    signIn = ChatSignInTarget(id: providerID)
                }
            }
        }
        .frame(maxWidth: ChatContentMetrics.maximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom)
        .accessibilityElement(children: .contain)
        .task(id: model.failedTurnID) { await model.refreshProviderAfterFailedTurn() }
        .sheet(item: $signIn) { ChatProviderSignInSheet(providerID: $0.id, store: model.store) }
    }
}

/// The provider a sign-in sheet opened for. Capturing it keeps the sheet up
/// once sign-in succeeds and the provider no longer reports signed out.
private struct ChatSignInTarget: Identifiable {
    let id: String
}

private struct ChatProviderSignInSheet: View {
    let providerID: String
    let store: ThreadStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProviderAccountDetailView(providerID: providerID, store: store)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
            .frame(minWidth: 500, minHeight: 440)
        #endif
    }
}
