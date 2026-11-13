import SwiftUI

struct ChatPromptQueueView: View {
    let model: ChatPromptModel

    private let composerOverlap: CGFloat = 24

    var body: some View {
        let queue = model.queue
        VStack(spacing: 0) {
            ForEach(Array(queue.enumerated()), id: \.element.id) { index, delivery in
                QueuedPromptRow(
                    model: model,
                    delivery: delivery,
                    previous: index > 0 ? queue[index - 1] : nil
                )
            }
        }
        .padding(.bottom, composerOverlap)
        .background(
            .regularMaterial,
            in: .rect(topLeadingRadius: 20, topTrailingRadius: 20)
        )
        .frame(maxWidth: ChatContentMetrics.maximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, -composerOverlap)
    }
}

/// A message waiting for the running turn, on its way, or one that didn't
/// get through.
private struct QueuedPromptRow: View {
    let model: ChatPromptModel
    let delivery: DeliveryView
    /// The message before it in the queue, to move it up past.
    let previous: DeliveryView?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isRefused ? "exclamationmark.circle.fill" : "arrow.turn.down.right")
                .foregroundStyle(isRefused ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                if delivery.from.kind != MaidActorKind.device.rawValue {
                    Text("From \(delivery.from.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    Self.summary(
                        text: delivery.text ?? "",
                        attachmentCount: delivery.attachments?.count ?? 0,
                        annotationCount: delivery.annotations?.count ?? 0
                    )
                )
                .lineLimit(1)
                if isRefused {
                    Text("Not delivered: \(delivery.reason ?? String(localized: "unknown error"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer()

            Group {
                switch delivery.deliveryState {
                case .sending:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sending")
                case .refused:
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await model.retry(delivery) }
                    }
                default:
                    Button(model.isTurnRunning ? "Steer" : "Send", systemImage: model.isTurnRunning ? "arrow.triangle.branch" : "arrow.up") {
                        Task { await model.sendNow(delivery) }
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.store.connectionState != .connected)

            if delivery.deliveryState != .sending {
                Button("Remove queued message", systemImage: "trash") {
                    Task { await model.cancel(delivery) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            if let previous, delivery.deliveryState == .queued, previous.deliveryState == .queued {
                Button("Move Up", systemImage: "arrow.up") {
                    Task { await model.move(delivery, before: previous) }
                }
            }
        }
    }

    private var isRefused: Bool { delivery.deliveryState == .refused }

    private static func summary(
        text: String,
        attachmentCount: Int,
        annotationCount: Int
    ) -> String {
        if !text.isEmpty { return text }
        if annotationCount > 0, attachmentCount > 0 {
            return "\(annotationCount) annotation(s) · \(attachmentCount) attachment(s)"
        }
        if annotationCount > 0 {
            return "\(annotationCount) annotation(s)"
        }
        return "\(attachmentCount) attachment(s)"
    }
}
