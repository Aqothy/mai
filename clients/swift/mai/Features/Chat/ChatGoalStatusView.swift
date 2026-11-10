import SwiftUI

/// The goal the agent pursues over its turns, shown above the composer while
/// the provider reports one. Labels follow the Codex TUI's goal indicator.
struct ChatGoalStatusView: View {
    let goal: Goal

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(status)
                    .layoutPriority(1)
                Text(goal.objective)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: ChatContentMetrics.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var status: String {
        switch MaidGoalStatus(rawValue: goal.status) {
        case .active: "Pursuing goal (\(activeUsage))"
        case .paused: "Goal paused"
        case .blocked: "Goal stalled"
        case .usageLimited: "Goal hit usage limits"
        case .budgetLimited:
            if let budget = goal.tokenBudget {
                "Goal unmet (\(Self.tokens(goal.tokensUsed)) / \(Self.tokens(budget)) tokens)"
            } else {
                "Goal unmet"
            }
        case .complete:
            goal.tokenBudget == nil
                ? "Goal achieved (\(Self.elapsed(goal.timeUsedSeconds)))"
                : "Goal achieved (\(Self.tokens(goal.tokensUsed)) tokens)"
        case nil: "Goal"
        }
    }

    /// Spent tokens against the budget, or the time spent without one.
    private var activeUsage: String {
        guard let budget = goal.tokenBudget else { return Self.elapsed(goal.timeUsedSeconds) }
        return "\(Self.tokens(goal.tokensUsed)) / \(Self.tokens(budget))"
    }

    private var systemImage: String {
        switch MaidGoalStatus(rawValue: goal.status) {
        case .complete: "checkmark.circle"
        case .paused: "pause.circle"
        case .blocked, .usageLimited, .budgetLimited: "exclamationmark.circle"
        case .active, nil: "scope"
        }
    }

    private static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    private static func elapsed(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        )
    }
}

#if DEBUG
    #Preview("Goal Status") {
        VStack {
            ChatGoalStatusView(
                goal: Goal(
                    objective: "Make the test suite pass without skipping tests",
                    status: MaidGoalStatus.active.rawValue,
                    timeUsedSeconds: 125,
                    tokenBudget: 50_000,
                    tokensUsed: 12_500
                )
            )
            ChatGoalStatusView(
                goal: Goal(
                    objective: "Ship it",
                    status: MaidGoalStatus.paused.rawValue,
                    timeUsedSeconds: 60,
                    tokenBudget: nil,
                    tokensUsed: 900
                )
            )
        }
    }
#endif
