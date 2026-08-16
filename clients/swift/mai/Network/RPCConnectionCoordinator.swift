import Foundation
import Observation

protocol RPCTransportClient: AnyObject {
    var onDisconnect: (((any Error)?) -> Void)? { get set }

    func connect()
    func disconnect()
}

/// Owns the app's one WebSocket lifecycle. Feature stores register the
/// synchronization work they need after each connection opens, while this
/// coordinator provides the shared timeout, retry, and disconnect behavior.
@Observable
final class RPCConnectionCoordinator {
    static let maximumReconnectAttempts = 5
    static let connectAttemptTimeout: Duration = .seconds(15)

    enum State {
        case disconnected
        case connecting
        case connected
    }

    struct Timing {
        fileprivate let fixedReconnectDelay: TimeInterval?

        static let standard = Timing(fixedReconnectDelay: nil)
        static let immediate = Timing(fixedReconnectDelay: 0)
    }

    private struct Participant {
        let prepare: () -> Void
        let synchronize: () async throws -> Void
        let connected: () -> Void
        let disconnected: ((any Error)?) -> Void
    }

    private(set) var state: State
    private(set) var reconnectAttempt = 0
    private(set) var nextReconnectAt: Date?

    var automaticReconnectsExhausted: Bool {
        state == .disconnected
            && reconnectAttempt >= Self.maximumReconnectAttempts
            && nextReconnectAt == nil
    }

    private let rpc: any RPCTransportClient
    private let timing: Timing
    private var participants: [Participant] = []
    private var reconnectTask: Task<Void, Never>?
    private var attemptID: UUID?

    init(
        rpc: any RPCTransportClient,
        timing: Timing = .standard,
        initiallyConnected: Bool = false
    ) {
        self.rpc = rpc
        self.timing = timing
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
        connected: @escaping () -> Void,
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
                RPCError(
                    code: nil,
                    message: "Connection attempt timed out",
                    data: nil
                ),
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
            state = .connected
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            nextReconnectAt = nil
            for participant in participants {
                participant.connected()
            }
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
        guard reconnectAttempt < Self.maximumReconnectAttempts else {
            nextReconnectAt = nil
            return
        }

        let attempt = reconnectAttempt + 1
        let delay: TimeInterval
        if let fixedReconnectDelay = timing.fixedReconnectDelay {
            delay = fixedReconnectDelay
        } else {
            let baseDelay = min(pow(2, Double(reconnectAttempt)), 30)
            delay = min(baseDelay * Double.random(in: 0.8...1.2), 30)
        }
        nextReconnectAt = Date().addingTimeInterval(delay)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            reconnectTask = nil
            reconnectAttempt = attempt
            await start()
        }
    }
}
