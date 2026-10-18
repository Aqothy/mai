import Foundation
import Observation

protocol RPCTransportClient: AnyObject {
    var onDisconnect: (((any Error)?) -> Void)? { get set }

    func connect()
    func disconnect()
    func checkConnection()
}

/// Owns the app's one WebSocket lifecycle. Feature stores register the
/// synchronization work they need after each connection opens, while this
/// coordinator provides the shared timeout, retry, and disconnect behavior.
@Observable
final class RPCConnectionCoordinator {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    static let connectAttemptTimeout: Duration = .seconds(15)
    private static let maximumReconnectDelay: Double = 30

    enum State {
        case disconnected
        case connecting
        case connected
    }

    private struct Participant {
        let prepare: () -> Void
        let synchronize: () async throws -> Void
        let connected: () async -> Void
        let disconnected: ((any Error)?) -> Void
    }

    private(set) var state: State
    private var reconnectAttempt = 0
    private(set) var nextReconnectAt: Date?

    private let rpc: any RPCTransportClient
    private var participants: [Participant] = []
    private var reconnectTask: Task<Void, Never>?
    private var attemptID: UUID?
    private var connectionID: UUID?

    init(
        rpc: any RPCTransportClient,
        initiallyConnected: Bool = false
    ) {
        self.rpc = rpc
        state = initiallyConnected ? .connected : .disconnected

        rpc.onDisconnect = { [weak self] error in
            self?.transportDidDisconnect(error)
        }
    }

    func uses(_ client: any RPCTransportClient) -> Bool {
        rpc === client
    }

    func register(
        prepare: @escaping () -> Void,
        synchronize: @escaping () async throws -> Void,
        connected: @escaping () async -> Void,
        disconnected: @escaping ((any Error)?) -> Void
    ) {
        participants.append(
            Participant(
                prepare: prepare,
                synchronize: synchronize,
                connected: connected,
                disconnected: disconnected
            ))
    }

    /// Opens the transport once, then synchronizes every registered feature on
    /// that same connection before publishing the connected state.
    func start() async {
        guard state != .connected, attemptID == nil else { return }

        state = .connecting
        nextReconnectAt = nil

        let id = UUID()
        attemptID = id
        for participant in participants {
            participant.prepare()
        }
        rpc.connect()

        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.connectAttemptTimeout)
            } catch {
                return
            }
            guard let self, attemptID == id else { return }
            failConnection(
                RPCError("Connection attempt timed out"),
                attemptID: id,
                disconnectTransport: true
            )
        }
        defer { watchdog.cancel() }

        do {
            // Keep initial publication deterministic: agent-thread state is
            // registered first, followed by terminal state, and both use the
            // same transport attempt and retry outcome.
            for participant in participants {
                try await participant.synchronize()
            }
            guard attemptID == id else { return }

            attemptID = nil
            connectionID = id
            state = .connected
            reconnectTask?.cancel()
            reconnectTask = nil
            nextReconnectAt = nil
            for participant in participants {
                await participant.connected()
            }
            // The connection counts as recovered only once every feature has
            // restored its subscriptions on it. One that a restore drops (a
            // snapshot the transport refuses) keeps its backoff growing
            // instead of reconnecting at the fastest rate.
            guard connectionID == id, state == .connected else { return }
            reconnectAttempt = 0
        } catch {
            failConnection(error, attemptID: id, disconnectTransport: true)
        }
    }

    func retry() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        nextReconnectAt = nil
        Task { [weak self] in
            await self?.start()
        }
    }

    /// Called when the app returns to the foreground. A socket that sat
    /// through a suspension can be dead without knowing it, and a pending
    /// reconnect shouldn't make the user wait out its backoff.
    func resume() {
        switch state {
        case .connected:
            rpc.checkConnection()
        case .disconnected:
            retry()
        case .connecting:
            break
        }
    }

    private func transportDidDisconnect(_ error: (any Error)?) {
        failConnection(error, attemptID: attemptID, disconnectTransport: false)
    }

    private func failConnection(
        _ error: (any Error)?,
        attemptID expectedAttemptID: UUID?,
        disconnectTransport: Bool
    ) {
        if let expectedAttemptID, attemptID != expectedAttemptID {
            return
        }
        guard attemptID != nil || state != .disconnected else { return }

        attemptID = nil
        connectionID = nil
        state = .disconnected
        for participant in participants {
            participant.disconnected(error)
        }
        if disconnectTransport {
            rpc.disconnect()
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        let attempt = reconnectAttempt + 1
        let baseDelay = min(pow(2, Double(reconnectAttempt)), Self.maximumReconnectDelay)
        let delay = min(baseDelay * Double.random(in: 0.8...1.2), Self.maximumReconnectDelay)
        nextReconnectAt = Date().addingTimeInterval(delay)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            reconnectTask = nil
            reconnectAttempt = attempt
            await start()
        }
    }
}
