import SwiftUI

/// A single step inside an expanded activity group, in the same compact
/// one-line style as the group row. Steps with output expand into a small
/// box; file edits open the diff viewer directly; steps with nothing more to
/// show are plain text, not buttons.
struct ChatActivityItemRow: View {
    let item: ChatItem
    let threadID: String
    let store: ThreadStore
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    // Captured at presentation: `detail` is cleared whenever the item
    // updates, and an open sheet must not lose its content to that.
    @State private var presentedChanges: [FileChange]?
    @State private var detail: Entry?
    @State private var isLoadingDetail = false
    @State private var detailErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isFileChangeStep || hasExpandableContent {
                    Button {
                        if opensDiffDirectly {
                            Task { await openDiff() }
                        } else {
                            scrollState.noteContentExpansion()
                            isExpanded.toggle()
                        }
                    } label: {
                        lineLabel
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    lineLabel
                }

                if item.isRunningInBackground {
                    ChatStopBackgroundItemButton(ref: item.ref, threadID: threadID, store: store)
                }
            }

            if isExpanded, hasExpandableContent || detailErrorMessage != nil {
                expandedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(
            isPresented: Binding(
                get: { presentedChanges != nil },
                set: { if !$0 { presentedChanges = nil } }
            )
        ) {
            UnifiedDiffView(changes: presentedChanges ?? [])
                .presentationDragIndicator(.visible)
        }
        .task(id: isExpanded) {
            // Also runs when a reused row reappears already expanded.
            if isExpanded, detail == nil, item.detailAvailable {
                await loadDetail()
            }
        }
        .onChange(of: updateKey) { _, _ in
            itemDidUpdate()
        }
    }

    private var lineLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: ChatActivityGroupRow.iconName(for: item))
                .font(.caption)
                .frame(width: 16)
                .foregroundStyle(
                    item.itemStatus == .failed
                        ? AnyShapeStyle(.red)
                        : AnyShapeStyle(.secondary)
                )

            ChatActivityGroupRow.itemLineText(item)
                .lineLimit(1)

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(item.itemStatus == .failed ? .red : .secondary)
            }

            if isFileChangeStep || hasExpandableContent {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let detailErrorMessage {
            HStack(spacing: 10) {
                Text(detailErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await loadDetail() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } else {
            if hasOutputContent {
                // Summary previews render instantly; fetched detail replaces
                // them in place without hiding already available output.
                ChatStepOutputBox(
                    itemID: item.id,
                    command: toolCall?.command ?? summary?.commandPreview,
                    query: toolCall?.query ?? summary?.queryPreview,
                    output: toolCall?.output ?? summary?.outputPreview,
                    outputIsMarkdown: (toolCall?.outputFormat ?? summary?.outputFormat)
                        == MaidOutputFormat.markdown.rawValue,
                    error: toolCall?.error ?? summary?.errorPreview,
                    metadata: metadata,
                    textLayoutStore: store.selectedThreadTextLayoutStore
                )
            }

            if let attachments = toolCall?.attachments, !attachments.isEmpty {
                ChatMessageAttachmentsView(attachments: attachments)
            } else if hasAttachmentSummary, detail == nil,
                item.detailAvailable
            {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading attachments…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if hasAttachmentSummary {
                Label(
                    "Attachments unavailable",
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isFileChangeStep,
                let changes = toolCall?.changes,
                !changes.isEmpty
            {
                Button(
                    "View Changes",
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    presentedChanges = changes
                }
                .font(.caption)
                .buttonStyle(.plain)
            }
        }
    }

    /// Fetched detail stays transient row state; the open choice is the
    /// reader's and outlives this row.
    private var isExpanded: Bool {
        get { foldModel.isExpanded(.activityItem(itemID: item.id)) }
        nonmutating set { foldModel.setExpanded(.activityItem(itemID: item.id), newValue) }
    }

    private var summary: ToolCallSummary? { item.tool }
    private var toolCall: ToolCall? { detail?.tool }

    /// Changes whenever the entry does, so a read whole entry isn't kept
    /// past its update.
    private var updateKey: String {
        let tool = item.tool
        return [
            item.entry.status ?? "", String(item.text?.count ?? 0), tool?.outputPreview ?? "",
            tool?.errorPreview ?? "", tool?.exitCode.map(String.init) ?? "", String(tool?.changeCount ?? 0),
        ].joined(separator: "|")
    }

    private var isFileChangeStep: Bool {
        ChatActivityVerb(item: item) == .edited
    }

    private var opensDiffDirectly: Bool {
        isFileChangeStep && !hasAttachmentSummary
    }

    private var hasAttachmentSummary: Bool {
        (summary?.attachmentCount ?? 0) > 0
            || summary?.attachments?.isEmpty == false
    }

    private var hasOutputContent: Bool {
        toolCall?.command != nil
            || summary?.commandPreview != nil
            || toolCall?.query != nil
            || summary?.queryPreview != nil
            || toolCall?.output != nil
            || summary?.outputPreview != nil
            || toolCall?.error != nil
            || summary?.errorPreview != nil
            || metadata != nil
    }

    /// Expandable only when there is genuinely more to show; a bare read
    /// with no output would otherwise expand into an empty box.
    private var hasExpandableContent: Bool {
        summary?.commandPreview != nil
            || summary?.queryPreview != nil
            || summary?.outputPreview != nil
            || summary?.errorPreview != nil
            || hasAttachmentSummary
    }

    private func openDiff() async {
        if detail == nil {
            await loadDetail()
        }
        if let changes = detail?.tool?.changes, !changes.isEmpty {
            presentedChanges = changes
        } else if hasExpandableContent || detailErrorMessage != nil {
            // No structured diff came back; fall back to whatever the step
            // can show instead of silently doing nothing.
            isExpanded = true
        }
    }

    private var statusText: String? {
        switch item.itemStatus {
        case .failed, .interrupted, .declined:
            item.itemStatus.map { ChatTimelineText.humanized($0.rawValue) }
        case .inProgress:
            item.isRunningInBackground ? "Running in background" : nil
        case .completed, nil:
            nil
        }
    }

    private var metadata: String? {
        var values: [String] = []
        let exitCode = toolCall?.exitCode ?? summary?.exitCode
        if let exitCode, exitCode != 0 {
            values.append("Exit \(exitCode)")
        }
        let duration = toolCall?.durationMilliseconds ?? summary?.durationMilliseconds
        if let duration, duration >= 100 {
            values.append("\(duration) ms")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func itemDidUpdate() {
        guard detail != nil else { return }
        detail = nil
        detailErrorMessage = nil
        if isExpanded, item.itemStatus != .inProgress {
            Task { await loadDetail() }
        }
    }

    private func loadDetail() async {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        detailErrorMessage = nil
        defer { isLoadingDetail = false }
        do {
            detail = try await store.entryDetail(threadID: threadID, item: item)
        } catch is CancellationError {
            return
        } catch {
            detailErrorMessage = error.localizedDescription
        }
    }
}

/// The rounded output panel under an expanded step: command, output, and
/// error in monospaced text.
private struct ChatStepOutputBox: View {
    private static let maximumCharacters = 4_000

    let itemID: String
    let command: String?
    let query: String?
    let output: String?
    /// Agent text (ACP tool content) is Markdown; command output is not.
    let outputIsMarkdown: Bool
    let error: String?
    let metadata: String?
    let textLayoutStore: ChatTextLayoutStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command, !command.isEmpty {
                monospacedText("$ " + command, style: .primary)
            }
            if let query, !query.isEmpty {
                Text(query)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let output, !output.isEmpty {
                if outputIsMarkdown, let textLayoutStore {
                    ChatMarkdownMessageView(
                        messageID: "\(itemID):output",
                        source: output,
                        presentation: ChatMarkdownPresentation(isStreaming: false),
                        textLayoutStore: textLayoutStore
                    )
                } else {
                    monospacedText(output, style: .secondary)
                }
            }
            if let error, !error.isEmpty {
                monospacedText(error, style: .red)
            }
            if let metadata {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func monospacedText(_ text: String, style: some ShapeStyle) -> some View {
        let (preview, isTruncated) = truncated(text)
        Text(preview)
            .font(.caption.monospaced())
            .foregroundStyle(style)
            .textSelection(.enabled)
        if isTruncated {
            Text("Preview truncated")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func truncated(_ text: String) -> (String, Bool) {
        guard
            let end = text.index(
                text.startIndex,
                offsetBy: Self.maximumCharacters,
                limitedBy: text.endIndex
            )
        else {
            return (text, false)
        }
        return (String(text[..<end]), end != text.endIndex)
    }
}

/// Stops a background task, such as a command run in the background. Sending
/// the stop does not end the task; the item's own update does, which removes
/// the button, so a stop that did not take can be sent again.
private struct ChatStopBackgroundItemButton: View {
    let ref: String
    let threadID: String
    let store: ThreadStore

    @State private var isStopping = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(isStopping ? "Stopping…" : "Stop", systemImage: "stop.circle") {
                Task { await stop() }
            }
            .disabled(isStopping || store.connectionState != .connected)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private func stop() async {
        isStopping = true
        defer { isStopping = false }
        do {
            try await store.stopItem(threadID: threadID, ref: ref)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
