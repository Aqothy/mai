import SwiftUI

/// One compact line summarizing a run of consecutive activity items, e.g.
/// "Read 2 files, ran a command". Tapping reveals the individual steps.
struct ChatActivityGroupRow: View {
    let group: ChatActivityGroup
    let threadID: String
    let store: ThreadStore
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    private var isExpanded: Bool {
        foldModel.isExpanded(.activityGroup(id: group.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                scrollState.noteContentExpansion()
                foldModel.setExpanded(.activityGroup(id: group.id), !isExpanded)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.iconName(for: group.items.first))
                        .font(.caption)
                        .frame(width: 16)
                        .foregroundStyle(
                            group.hasFailure
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.secondary)
                        )

                    Text(group.summary)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.items, id: \.id) { item in
                        ChatActivityItemRow(
                            item: item,
                            threadID: threadID,
                            store: store,
                            foldModel: foldModel,
                            scrollState: scrollState
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A single-step group shows its specific work instead of an aggregate.
    static func itemLineText(_ item: ChatItem) -> Text {
        let summary = item.tool
        let verb = ChatActivityVerb(item: item)
        switch verb {
        case .ranCommand:
            if let command = summary?.commandPreview, !command.isEmpty {
                return Text("Ran \(monospaced(command))")
            }
        case .thought:
            return Text("Thought")
        case .read:
            if let path = summary?.locations?.first?.path, !path.isEmpty {
                return Text("Read \(monospaced(lastPathComponent(path)))")
            }
        case .edited:
            if let path = summary?.changes?.first?.path, !path.isEmpty {
                let extra = max(0, (summary?.changeCount ?? 1) - 1)
                let suffix = extra > 0 ? " +\(extra)" : ""
                return Text("Edited \(monospaced(lastPathComponent(path)))\(suffix)")
            }
        case .searched:
            if let query = summary?.queryPreview, !query.isEmpty {
                return Text("Searched \(monospaced(query))")
            }
        case .tool:
            break
        }
        if let title = item.title, !title.isEmpty {
            return Text(title)
        }
        return Text(verb.phrase(count: 1, leading: true))
    }

    private static func monospaced(_ value: String) -> Text {
        Text(value).font(.callout.monospaced())
    }

    private static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func iconName(for item: ChatItem?) -> String {
        guard let item else { return "circle.dashed" }
        return switch ChatActivityVerb(item: item) {
        case .thought: "brain"
        case .read: "book"
        case .searched: "magnifyingglass"
        case .edited: "pencil"
        case .ranCommand: "terminal"
        case .tool: "wrench.and.screwdriver"
        }
    }
}
