import Observation
import SwiftUI

nonisolated enum UnifiedDiffSource: Hashable, Sendable {
    struct ToolChange: Hashable, Sendable {
        let path: String
        let kind: String?
        let diff: String?
        let oldText: String?
        let newText: String?
        let movePath: String?

        init(_ change: FileChange) {
            path = change.path
            kind = change.kind
            diff = change.diff
            oldText = change.oldText
            newText = change.newText
            movePath = change.movePath
        }
    }

    case patch(String)
    case toolChanges([ToolChange])

    nonisolated func makeDocument() -> UnifiedDiffDocument {
        switch self {
        case .patch(let patch):
            UnifiedDiffParser.parse(patch)
        case .toolChanges(let changes):
            UnifiedDiffFileChangeAdapter.adapt(changes)
        }
    }
}

@Observable
private final class UnifiedDiffLoader {
    private(set) var document = UnifiedDiffDocument.empty
    private(set) var isLoading = true

    private var loadedSource: UnifiedDiffSource?

    func load(_ source: UnifiedDiffSource) async {
        guard loadedSource != source else { return }
        isLoading = true

        let document = await Task.detached(priority: .userInitiated) {
            source.makeDocument()
        }.value
        guard !Task.isCancelled else { return }

        self.document = document
        loadedSource = source
        isLoading = false
    }
}

struct UnifiedDiffView: View {
    private let source: UnifiedDiffSource

    @State private var loader = UnifiedDiffLoader()

    init(patch: String) {
        source = .patch(patch)
    }

    init(changes: [FileChange]) {
        source = .toolChanges(changes.map(UnifiedDiffSource.ToolChange.init))
    }

    var body: some View {
        Group {
            if loader.isLoading {
                ProgressView("Parsing diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UnifiedDiffDocumentView(document: loader.document)
            }
        }
        .task(id: source) {
            await loader.load(source)
        }
    }
}

private struct UnifiedDiffDocumentView: View {
    let document: UnifiedDiffDocument

    var body: some View {
        if document.files.isEmpty {
            ContentUnavailableView(
                "No Diff Content",
                systemImage: "doc.text.magnifyingglass",
                description: Text("The patch is empty or contains no usable lines.")
            )
        } else {
            List {
                ForEach(document.rows) { row in
                    UnifiedDiffRowView(row: row)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .textSelection(.enabled)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 16, for: .scrollContent)
        }
    }
}

private struct UnifiedDiffRowView: View {
    let row: UnifiedDiffPresentationRow

    var body: some View {
        // The single-root container keeps the row unary so List can template
        // row ids from the ForEach without evaluating every row's body.
        VStack(spacing: 0) {
            switch row {
            case .file(let file):
                UnifiedDiffFileHeaderView(file: file)
            case .metadata(_, _, let text):
                UnifiedDiffMetadataLineView(text: text)
            case .binary(let file):
                UnifiedDiffBinaryFileView(file: file)
            case .hunk(_, let hunk):
                UnifiedDiffHunkHeaderView(hunk: hunk)
            case .line(_, _, let line):
                UnifiedDiffLineView(line: line)
            }
        }
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
    }

    private var rowInsets: EdgeInsets {
        switch row {
        case .file:
            .init(top: 12, leading: 12, bottom: 8, trailing: 12)
        case .metadata:
            .init(top: 2, leading: 12, bottom: 2, trailing: 12)
        case .binary:
            .init(top: 8, leading: 12, bottom: 12, trailing: 12)
        case .hunk, .line:
            .init()
        }
    }
}

private struct UnifiedDiffFileHeaderView: View {
    let file: UnifiedDiffFile

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)

                Text(verbatim: file.displayPath)
                    .font(.headline.monospaced())
                    .bold()

                Spacer()

                Text(file.status.label)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusTint.opacity(badgeOpacity), in: .capsule)

                if file.isBinary {
                    Text("Binary")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(badgeOpacity), in: .capsule)
                }
            }

            if file.pathDescription != file.displayPath {
                Text(verbatim: file.pathDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var badgeOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.16
    }

    private var statusTint: Color {
        switch file.status {
        case .modified:
            .blue
        case .added:
            .green
        case .deleted:
            .red
        case .renamed:
            .purple
        case .unknown:
            .secondary
        }
    }
}

private struct UnifiedDiffMetadataLineView: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.06))
    }
}

private struct UnifiedDiffBinaryFileView: View {
    let file: UnifiedDiffFile

    var body: some View {
        Label(
            "Binary content is not rendered",
            systemImage: "doc.badge.ellipsis"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint(file.pathDescription)
    }
}

private struct UnifiedDiffHunkHeaderView: View {
    let hunk: UnifiedDiffHunk

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(verbatim: hunk.header.isEmpty ? "Partial hunk" : hunk.header)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
    }
}

private struct UnifiedDiffLineView: View {
    let line: UnifiedDiffLine

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(displayedLineNumber.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 32, idealWidth: 40, alignment: .trailing)
                .padding(.trailing, 4)

            Text(verbatim: line.kind.prefix)
                .font(.callout.monospaced())
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .center)

            Group {
                if let attributedContent = line.attributedContent {
                    Text(attributedContent)
                } else {
                    Text(verbatim: line.content)
                }
            }
            .font(.callout.monospaced())
            .foregroundStyle(contentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(backgroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayedLineNumber: Int? {
        switch line.kind {
        case .deletion:
            line.oldLineNumber
        case .context, .addition:
            line.newLineNumber
        case .noNewline, .unsupported:
            nil
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context:
            .secondary.opacity(colorScheme == .dark ? 0.04 : 0.025)
        case .addition:
            .green.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .deletion:
            .red.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .noNewline:
            .orange.opacity(colorScheme == .dark ? 0.16 : 0.08)
        case .unsupported:
            .yellow.opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition:
            .green
        case .deletion:
            .red
        case .noNewline:
            .orange
        case .context, .unsupported:
            .secondary
        }
    }

    private var contentColor: Color {
        switch line.kind {
        case .noNewline, .unsupported:
            .secondary
        case .context, .addition, .deletion:
            .primary
        }
    }

    private var accessibilityLabel: String {
        let kind =
            switch line.kind {
            case .context:
                "Context"
            case .addition:
                "Addition"
            case .deletion:
                "Deletion"
            case .noNewline:
                "Marker"
            case .unsupported:
                "Unsupported line"
            }
        let old = line.oldLineNumber.map { "old line \($0)" } ?? ""
        let new = line.newLineNumber.map { "new line \($0)" } ?? ""
        return [kind, old, new, line.content].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct UnifiedDiffLauncherView: View {
    let changes: [FileChange]

    @State private var isPresented = false

    var body: some View {
        Button(
            "View \(changes.count.formatted()) file "
                + (changes.count == 1 ? "change" : "changes"),
            systemImage: "doc.text.magnifyingglass"
        ) {
            isPresented = true
        }
        .sheet(isPresented: $isPresented) {
            UnifiedDiffView(changes: changes)
                .presentationDragIndicator(.visible)
        }
    }
}

#Preview("Unified diff") {
    UnifiedDiffView(
        patch: """
                diff --git a/Sources/Greeting.swift b/Sources/Greeting.swift
                index 8f83a2a..4c19f0e 100644
                --- a/Sources/Greeting.swift
                +++ b/Sources/Greeting.swift
                @@ -1,5 +1,7 @@
                 import SwiftUI
                 
                 struct Greeting: View {
                -    let name = "World"
                +    let name: String
                +    let punctuation = "!"
                +    let previewMessage = "This deliberately long diff line wraps naturally so every character remains visible without horizontal scrolling."
                 
                     var body: some View {
            """
    )
}
