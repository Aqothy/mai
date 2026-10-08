import SwiftUI

/// Says why the latest turn ended early (output limit, request limit, or the
/// agent refusing), which would otherwise look like a normal finish.
struct ChatTurnStopNoticeView: View {
    let reason: MaidStopReason

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: ChatContentMetrics.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var message: LocalizedStringResource {
        switch reason {
        case .refusal: "The agent refused to continue."
        case .maxTokens: "The response stopped at the model's output limit."
        case .maxTurnRequests: "The turn stopped at the agent's request limit."
        }
    }
}
