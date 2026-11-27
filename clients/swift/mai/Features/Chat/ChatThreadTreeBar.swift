import SwiftUI

/// Where the open chat sits in its tree: the chat that started it or that
/// it was forked from, and the chats it started (subagents, spawned and
/// forked chats), each with its status, so the user can follow the work at
/// any depth.
struct ChatThreadTreeBar: View {
    /// A title's width before it truncates; in a horizontal scroll view a
    /// title would otherwise take all the width it wants.
    private static let titleWidth: CGFloat = 220

    let parent: ThreadSummary?
    let forkedFrom: ThreadSummary?
    let children: [ThreadSummary]
    let openThread: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let parent {
                    Button {
                        openThread(parent.id)
                    } label: {
                        Label {
                            Text(parent.title)
                                .lineLimit(1)
                                .frame(maxWidth: Self.titleWidth)
                        } icon: {
                            Image(systemName: "arrow.up.left")
                        }
                    }
                    .accessibilityLabel("Started by \(parent.title)")
                } else if let forkedFrom {
                    Button {
                        openThread(forkedFrom.id)
                    } label: {
                        Label {
                            Text(forkedFrom.title)
                                .lineLimit(1)
                                .frame(maxWidth: Self.titleWidth)
                        } icon: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                    }
                    .accessibilityLabel("Forked from \(forkedFrom.title)")
                }
                ForEach(children, id: \.id) { child in
                    Button {
                        openThread(child.id)
                    } label: {
                        HStack(spacing: 4) {
                            ThreadRowStatusView(status: child.rowIndicatorStatus)
                            Image(systemName: child.origin.forkedFrom == nil ? "person.2" : "arrow.triangle.branch")
                                .accessibilityHidden(true)
                            Text(child.title)
                                .lineLimit(1)
                                .frame(maxWidth: Self.titleWidth)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: ChatContentMetrics.maximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}
