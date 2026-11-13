import SwiftUI

/// Why a chat's queue waits — stopped, failed, or agents going back and
/// forth too long — and the way to let it go on.
struct ChatHoldView: View {
    let model: ChatPromptModel
    let hold: MaidHold

    var body: some View {
        HStack {
            Label(message, systemImage: "pause.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Continue", systemImage: "play.fill") {
                Task { await model.continueThread() }
            }
            .disabled(model.store.connectionState != .connected)
        }
        .frame(maxWidth: ChatContentMetrics.maximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var message: String {
        switch hold {
        case .stoppedPerson: String(localized: "Stopped. Messages wait until you continue.")
        case .stoppedAgent: String(localized: "An agent stopped this chat. Messages wait until it continues.")
        case .failed: String(localized: "A turn failed. Messages wait until you continue.")
        case .hops: String(localized: "Agents went back and forth too long. Messages wait until you continue.")
        }
    }
}
