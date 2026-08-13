import Foundation
import Synchronization

/// A process-wide cache for settled Markdown values.
///
/// The loaded chat is intentionally retained without eviction. Timeline rows
/// can be destroyed and recreated while scrolling, so unchanged messages must
/// not reparse solely because they left the viewport.
nonisolated final class ChatMarkdownRenderCache: Sendable {
    static let shared = ChatMarkdownRenderCache()

    private struct Entry: Sendable {
        let source: String
        let plan: ChatMarkdownRenderPlan
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var warming: Set<ChatMarkdownRenderRequest> = []
    }

    private let state = Mutex(State())

    func plan(
        messageID: String,
        source: String
    ) -> ChatMarkdownRenderPlan {
        if let cached = state.withLock({ state in
            state.entries[messageID].flatMap {
                $0.source == source ? $0.plan : nil
            }
        }) {
            return cached
        }

        let rendered = ChatMarkdownRenderPlanner.plan(from: source)
        return store(
            rendered,
            messageID: messageID,
            source: source
        )
    }

    /// Starts best-effort background preparation without tying the work to a
    /// view's lifetime. Duplicate requests are claimed once.
    func warm(requests: [ChatMarkdownRenderRequest]) {
        let pending = claim(requests)
        guard !pending.isEmpty else { return }

        Task.detached(priority: .utility) { [self] in
            for request in pending {
                guard !Task.isCancelled else { break }
                let plan = ChatMarkdownRenderPlanner.plan(from: request.source)
                _ = store(
                    plan,
                    messageID: request.messageID,
                    source: request.source
                )
                finish(request)
            }
            if Task.isCancelled {
                for request in pending {
                    finish(request)
                }
            }
        }
    }

    /// Awaitable preparation used before an older transcript page is inserted.
    func prime(requests: [ChatMarkdownRenderRequest]) async {
        let pending = claim(requests)
        guard !pending.isEmpty else { return }

        let worker = Task.detached(priority: .userInitiated) {
            var values: [(ChatMarkdownRenderRequest, ChatMarkdownRenderPlan)] = []
            values.reserveCapacity(pending.count)
            for request in pending {
                guard !Task.isCancelled else { break }
                values.append(
                    (request, ChatMarkdownRenderPlanner.plan(from: request.source))
                )
            }
            return values
        }
        let values = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        for (request, plan) in values {
            _ = store(
                plan,
                messageID: request.messageID,
                source: request.source
            )
        }
        for request in pending {
            finish(request)
        }
    }

    private func claim(
        _ requests: [ChatMarkdownRenderRequest]
    ) -> [ChatMarkdownRenderRequest] {
        state.withLock { state in
            var pending: [ChatMarkdownRenderRequest] = []
            pending.reserveCapacity(requests.count)
            for request in requests {
                guard state.entries[request.messageID]?.source != request.source,
                    state.warming.insert(request).inserted
                else { continue }
                pending.append(request)
            }
            return pending
        }
    }

    private func finish(_ request: ChatMarkdownRenderRequest) {
        state.withLock { state in
            _ = state.warming.remove(request)
        }
    }

    private func store(
        _ plan: ChatMarkdownRenderPlan,
        messageID: String,
        source: String
    ) -> ChatMarkdownRenderPlan {
        state.withLock { state in
            if let entry = state.entries[messageID], entry.source == source {
                return entry.plan
            }
            state.entries[messageID] = Entry(source: source, plan: plan)
            return plan
        }
    }
}
