import Foundation
import Observation

@Observable
final class ThreadStore {
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
    }

    private(set) var threads: [ThreadListEntry] = []
    private(set) var selectedThreadID: String?
    private(set) var selectedThread: Thread?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var errorMessage: String?

    private let rpc: MaidRPCClient
    private var isStarted = false
    private var lastThreadListSequence = 0
    private var isLoadingThreadListSnapshot = false
    private var bufferedThreadListItems: [ThreadListStreamItem] = []
    private var selectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init() {
        rpc = MaidRPCClient()
    }

    init(rpc: MaidRPCClient) {
        self.rpc = rpc
    }

    #if DEBUG
    init(previewThreads: [ThreadListEntry], selectedThread: Thread? = nil) {
        rpc = MaidRPCClient()
        threads = previewThreads
        self.selectedThread = selectedThread
        selectedThreadID = selectedThread?.id
        connectionState = .connected
    }
    #endif

    func start() async {
        guard !isStarted else { return }

        isStarted = true
        connectionState = .connecting
        errorMessage = nil
        isLoadingThreadListSnapshot = true

        rpc.onNotification = { [weak self] method, data in
            self?.receiveNotification(method: method, data: data)
        }
        rpc.onDisconnect = { [weak self] error in
            guard let self else { return }
            isStarted = false
            connectionState = .disconnected
            selectedThread = nil
            if let error {
                errorMessage = error.localizedDescription
            }
            scheduleReconnect()
        }
        rpc.connect()

        do {
            let item: ThreadListStreamItem = try await rpc.call(
                MaidRPCMethod.orchestrationSubscribeThreadList,
                params: EmptyParams()
            )
            applyThreadListSnapshot(item)
            connectionState = .connected
            reconnectTask?.cancel()
            reconnectTask = nil
            await restoreSelectedThread()
        } catch {
            isLoadingThreadListSnapshot = false
            bufferedThreadListItems.removeAll()
            connectionState = .disconnected
            errorMessage = error.localizedDescription
            isStarted = false
            rpc.disconnect()
        }
    }

    func retry() {
        guard !isStarted else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        Task {
            await start()
        }
    }

    func selectThread(_ id: String?) {
        guard selectedThreadID != id else { return }

        let previousID = selectedThreadID
        selectedThreadID = id
        selectedThread = nil
        errorMessage = nil
        selectionTask?.cancel()

        selectionTask = Task { [weak self] in
            guard let self else { return }

            if let previousID {
                try? await rpc.callVoid(
                    MaidRPCMethod.orchestrationUnsubscribeThread,
                    params: SubscribeThreadInput(threadID: previousID)
                )
            }

            guard !Task.isCancelled, let id else { return }

            do {
                let item: ThreadStreamItem = try await rpc.call(
                    MaidRPCMethod.orchestrationSubscribeThread,
                    params: SubscribeThreadInput(threadID: id)
                )
                guard !Task.isCancelled, selectedThreadID == id else { return }
                selectedThread = item.snapshot?.thread
            } catch is CancellationError {
                return
            } catch {
                guard selectedThreadID == id else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restoreSelectedThread() async {
        guard let id = selectedThreadID else { return }

        do {
            let item: ThreadStreamItem = try await rpc.call(
                MaidRPCMethod.orchestrationSubscribeThread,
                params: SubscribeThreadInput(threadID: id)
            )
            guard selectedThreadID == id else { return }
            selectedThread = item.snapshot?.thread
        } catch {
            guard selectedThreadID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self else { return }
            reconnectTask = nil
            await start()
        }
    }

    private func receiveNotification(method: String, data: Data) {
        do {
            switch method {
            case MaidRPCMethod.orchestrationSubscribeThreadList:
                let notification = try newJSONDecoder().decode(
                    Notification<ThreadListStreamItem>.self,
                    from: data
                )
                receiveThreadListItem(notification.params)
            case MaidRPCMethod.orchestrationSubscribeThread:
                // The detail event reducer will be added with the chat timeline.
                break
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func receiveThreadListItem(_ item: ThreadListStreamItem) {
        if isLoadingThreadListSnapshot {
            bufferedThreadListItems.append(item)
        } else {
            applyThreadListUpdate(item)
        }
    }

    private func applyThreadListSnapshot(_ item: ThreadListStreamItem) {
        guard item.kind == "snapshot", let snapshot = item.snapshot else {
            errorMessage = "maiD returned an invalid thread-list snapshot"
            isLoadingThreadListSnapshot = false
            return
        }

        lastThreadListSequence = snapshot.snapshotSequence
        threads = snapshot.threads.filter { !$0.draft }
        sortThreads()
        isLoadingThreadListSnapshot = false

        let bufferedItems = bufferedThreadListItems
        bufferedThreadListItems.removeAll()
        for bufferedItem in bufferedItems.sorted(by: streamSequenceAscending) {
            applyThreadListUpdate(bufferedItem)
        }
    }

    private func applyThreadListUpdate(_ item: ThreadListStreamItem) {
        guard let sequence = item.sequence, sequence > lastThreadListSequence else { return }
        lastThreadListSequence = sequence

        switch item.kind {
        case "thread-upserted":
            guard let thread = item.thread else { return }
            threads.removeAll { $0.id == thread.id }
            if !thread.draft {
                threads.append(thread)
            }
            sortThreads()
        case "thread-removed":
            guard let threadID = item.threadID else { return }
            threads.removeAll { $0.id == threadID }
            if selectedThreadID == threadID {
                selectThread(nil)
            }
        default:
            break
        }
    }

    private func sortThreads() {
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func streamSequenceAscending(
        _ left: ThreadListStreamItem,
        _ right: ThreadListStreamItem
    ) -> Bool {
        (left.sequence ?? .min) < (right.sequence ?? .min)
    }

    private struct Notification<Params: Decodable>: Decodable {
        let params: Params
    }
}
