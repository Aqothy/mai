import SwiftUI

struct ChatPlanRow: View {
    let plan: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading) {
            Label("Plan", systemImage: "checklist")
                .bold()

            // PlanEntry has no stable key and plans are replaced wholesale.
            ForEach(plan.indices, id: \.self) { index in
                let entry = plan[index]
                HStack(alignment: .firstTextBaseline) {
                    Image(
                        systemName: entry.status == "completed" ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(entry.status == "completed" ? .green : .secondary)
                    Text(entry.content)
                    Spacer()
                    if let status = entry.status {
                        Text(ChatTimelineText.humanized(status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
