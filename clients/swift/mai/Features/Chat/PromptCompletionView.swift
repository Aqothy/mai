import SwiftUI

private enum PromptCompletionLayout {
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 2
    static let contentInset: CGFloat = 6
    static let maximumVisibleRowCount = 5
}

struct PromptCompletionView: View {
    let model: PromptCompletionModel
    let select: (PromptCompletionMatch) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PromptCompletionHeader(kind: model.kind)

            Divider()

            if model.phase == .results, !model.matches.isEmpty {
                PromptCompletionResultsView(
                    matches: model.matches,
                    selectedMatchID: model.selectedMatchID,
                    select: select
                )
            } else {
                PromptCompletionStatusView(
                    kind: model.kind,
                    phase: model.phase,
                    query: model.query,
                    retry: model.retry
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: panelHeight)
        .clipShape(.rect(cornerRadius: 16))
        .glassSurface(in: .rect(cornerRadius: 16), isShadowed: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .task(id: model.searchKey) {
            await model.search()
        }
    }

    private var panelHeight: CGFloat {
        let contentHeight: CGFloat
        if model.phase == .results, !model.matches.isEmpty {
            let rowCount = min(
                model.matches.count,
                PromptCompletionLayout.maximumVisibleRowCount
            )
            contentHeight = CGFloat(rowCount) * PromptCompletionLayout.rowHeight
                + CGFloat(max(rowCount - 1, 0)) * PromptCompletionLayout.rowSpacing
                + 2 * PromptCompletionLayout.contentInset
        } else {
            contentHeight = 52
        }
        return PromptCompletionLayout.headerHeight + 1 + contentHeight
    }

    private var accessibilityLabel: String {
        guard let kind = model.kind else { return "Prompt suggestions" }
        if model.matches.isEmpty {
            return "\(kind.panelTitle) suggestions"
        }
        return "\(model.matches.count) \(kind.panelTitle.lowercased()) suggestions"
    }
}

private struct PromptCompletionHeader: View {
    let kind: PromptCompletionKind?

    var body: some View {
        HStack {
            if let kind {
                Label(kind.panelTitle, systemImage: kind.systemImage)
            } else {
                Text("Suggestions")
            }

            Spacer()

            Text("↑↓ choose  ↵ insert")
                .monospaced()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: PromptCompletionLayout.headerHeight)
    }
}

private struct PromptCompletionResultsView: View {
    let matches: [PromptCompletionMatch]
    let selectedMatchID: PromptCompletionMatch.ID?
    let select: (PromptCompletionMatch) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PromptCompletionLayout.rowSpacing) {
                    ForEach(matches) { match in
                        PromptCompletionRow(
                            match: match,
                            isSelected: match.id == selectedMatchID
                        ) {
                            select(match)
                        }
                        .id(match.id)
                    }
                }
                .padding(PromptCompletionLayout.contentInset)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedMatchID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct PromptCompletionRow: View {
    let match: PromptCompletionMatch
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: match.systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title)
                        .font(.callout)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let subtitle = match.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let inputHint = match.inputHint, !inputHint.isEmpty {
                    Text(inputHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: .capsule)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: PromptCompletionLayout.rowHeight)
            .background(
                isSelected ? Color.primary.opacity(0.1) : Color.clear,
                in: .rect(cornerRadius: 10)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Inserts this suggestion into the prompt.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        [match.title, match.subtitle, match.inputHint]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }
}

private struct PromptCompletionStatusView: View {
    let kind: PromptCompletionKind?
    let phase: PromptCompletionModel.Phase
    let query: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                Text(kind == .workspaceFile ? "Searching files…" : "Loading suggestions…")
            case .indexing:
                ProgressView()
                    .controlSize(.small)
                Text("Indexing files…")
                Spacer()
                Button("Check Again", action: retry)
            case .results:
                Label(emptyMessage, systemImage: kind?.emptySystemImage ?? "text.magnifyingglass")
            case .failed:
                Label("Couldn’t search files", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Try Again", action: retry)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        let noun = kind?.panelTitle.lowercased() ?? "suggestions"
        return query.isEmpty ? "No \(noun) available" : "No matching \(noun)"
    }
}

private extension PromptCompletionKind {
    var panelTitle: String {
        switch self {
        case .workspaceFile: "Files"
        case .slashCommand: "Commands"
        case .skill: "Skills"
        }
    }

    var systemImage: String {
        switch self {
        case .workspaceFile: "doc.text.magnifyingglass"
        case .slashCommand: "slash.circle"
        case .skill: "sparkles"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .workspaceFile: "doc.text.magnifyingglass"
        case .slashCommand: "slash.circle"
        case .skill: "sparkles"
        }
    }
}
