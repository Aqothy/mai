import Foundation
import Synchronization

final class RPCClient {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private static let notificationQueueLimit = 1_024
    /// How often the socket is pinged and how long a pong may take. A link
    /// that went half-open (a network change, a suspension, a stalled proxy)
    /// otherwise looks connected while every call hangs; the daemon pings on
    /// the same cadence and drops the connection from its side too.
    private static let pingInterval: Duration = .seconds(15)
    /// A probe answers whether the socket survived a suspension, so it can't
    /// wait as long as the periodic ping: the user is looking at the screen.
    private static let probeTimeout: Duration = .seconds(5)

    var onNotification: ((String, Data) -> Void)?
    /// Receives terminal output off the main actor, in arrival order.
    var onTerminalStreamItem: (@Sendable (TerminalStreamMessage) -> Void)? {
        get { terminalSink.handler }
        set { terminalSink.handler = newValue }
    }

    /// The receive loop reads the terminal handler off the main actor.
    private let terminalSink = TerminalSink()
    var onTerminalListItem: ((TerminalListStreamItem) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let endpoint = RPCClient.configuredEndpoint
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var notifyContinuation: AsyncStream<String>.Continuation?
    private var notifyTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private static var configuredEndpoint: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MAI_RPC_URL") as? String,
           let endpoint = URL(string: value),
           endpoint.host != nil,
           let scheme = endpoint.scheme?.lowercased(),
           ["ws", "wss"].contains(scheme) {
            return endpoint
        }
        return URL(string: "ws://127.0.0.1:8765/rpc")!
    }

    func connect() {
        guard webSocket == nil else { return }

        let socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 64 * 1_024 * 1_024
        webSocket = socket
        socket.resume()

        let terminalSink = terminalSink
        receiveTask = Task { [weak self] in
            await Self.receiveMessages(
                from: socket,
                terminalSink: terminalSink,
                route: { [weak self] envelope, data in self?.route(envelope, data: data) },
                finish: { [weak self] failure in
                    self?.finishConnection(socket, error: failure.map { RPCError($0.message) })
                })
        }
        pingTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: Self.pingInterval)
                } catch {
                    return
                }
                guard let self else { return }
                await ping(socket, timeout: Self.pingInterval)
            }
        }

        // One consumer drains notifications sequentially so fire-and-forget
        // sends (terminal input, resize) keep their order on the wire.
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingOldest(Self.notificationQueueLimit)
        )
        notifyContinuation = continuation
        notifyTask = Task { [weak self] in
            for await text in stream {
                do {
                    try await socket.send(.string(text))
                } catch {
                    self?.finishConnection(socket, error: error)
                    break
                }
            }
        }
    }

    func disconnect() {
        guard let socket = webSocket else { return }
        finishConnection(socket, error: nil)
    }

    /// Pings the socket now and closes it, through `onDisconnect`, when the
    /// pong doesn't come back soon.
    func checkConnection() {
        guard let socket = webSocket else { return }
        Task { [weak self] in
            await self?.ping(socket, timeout: Self.probeTimeout)
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask, timeout: Duration) async {
        // A half-open link never calls the pong handler, so the deadline
        // closes the socket, which then fails the ping.
        let deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finishConnection(socket, error: RPCError("maiD stopped responding"))
        }
        let answered = await withCheckedContinuation { continuation in
            socket.sendPing { error in
                continuation.resume(returning: error == nil)
            }
        }
        deadline.cancel()
        if !answered {
            finishConnection(socket, error: RPCError("maiD stopped responding"))
        }
    }

    func call<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: sending Params
    ) async throws -> Result {
        let data = try await sendRequestAndWaitForResponse(method, params: params)
        let response = try await Self.decode(Response<Result>.self, from: data)

        if let error = response.error {
            throw RPCError(code: error.code, message: error.message, data: error.data)
        }
        guard let result = response.result else {
            throw RPCError("maiD returned no result for \(method)")
        }
        return result
    }

    /// Sends a JSON-RPC notification: no id and no response. Payloads are
    /// encoded inline (they are small, unlike attachment-heavy calls) and
    /// delivered in call order. Transport failures close the connection and
    /// surface through `onDisconnect`.
    func notify<Params: Encodable>(_ method: String, params: Params) {
        guard webSocket != nil, let continuation = notifyContinuation else { return }
        guard let text = try? Self.encodeInline(NotificationRequest(method: method, params: params)) else {
            return
        }
        switch continuation.yield(text) {
        case .enqueued, .terminated:
            break
        case .dropped:
            guard let socket = webSocket else { return }
            finishConnection(
                socket,
                error: RPCError("Client notification queue is full")
            )
        @unknown default:
            break
        }
    }

    func callVoid<Params: Encodable>(
        _ method: String,
        params: sending Params
    ) async throws {
        let data = try await sendRequestAndWaitForResponse(method, params: params)
        let response = try await Self.decode(ErrorResponse.self, from: data)
        if let error = response.error {
            throw RPCError(code: error.code, message: error.message, data: error.data)
        }
    }

    @concurrent
    private static func decode<Value: Decodable & SendableMetatype>(
        _ type: Value.Type,
        from data: Data
    ) async throws -> sending Value {
        try WireJSON.makeDecoder().decode(type, from: data)
    }

    // Encoding runs off the main actor for the same reason decoding does: a
    // thread.turn.start with base64 image/audio attachments is a multi-MB
    // JSON body, and escaping it inline in the send path is a visible hitch.
    @concurrent
    private static func encode<Value: Encodable & SendableMetatype>(
        _ value: sending Value
    ) async throws -> String {
        try encodeInline(value)
    }

    private func sendRequestAndWaitForResponse<Params: Encodable>(
        _ method: String,
        params: sending Params
    ) async throws -> Data {
        guard webSocket != nil else {
            throw RPCError("Not connected to maiD")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let requestText = try await Self.encode(
            Request(id: requestID, method: method, params: params)
        )
        guard let socket = webSocket else {
            throw RPCError("Not connected to maiD")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = continuation

                Task { [weak self] in
                    await self?.sendMessage(
                        requestText,
                        requestID: requestID,
                        over: socket
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID)
            }
        }
    }

    private func sendMessage(
        _ requestText: String,
        requestID: Int,
        over socket: URLSessionWebSocketTask
    ) async {
        guard pendingRequests[requestID] != nil else { return }

        do {
            try await socket.send(.string(requestText))
        } catch {
            finishConnection(socket, error: error)
        }
    }

    /// Receives off the main actor. Terminal output goes straight to
    /// `terminalSink` and never touches the main actor; everything else is
    /// routed there in arrival order.
    @concurrent
    private nonisolated static func receiveMessages(
        from socket: URLSessionWebSocketTask,
        terminalSink: TerminalSink,
        route: @escaping @MainActor (Envelope, Data) -> Void,
        finish: @escaping @MainActor (ReceiveFailure?) -> Void
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data

                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data:
                    throw ReceiveFailure(message: "maiD sent a binary WebSocket frame")
                @unknown default:
                    throw ReceiveFailure(message: "maiD sent an unknown WebSocket frame")
                }

                let envelope = try WireJSON.makeDecoder().decode(Envelope.self, from: data)
                if let item = envelope.params, let handler = terminalSink.handler {
                    handler(item)
                } else {
                    await route(envelope, data)
                }
            }
            await finish(nil)
        } catch is CancellationError {
            await finish(nil)
        } catch let failure as ReceiveFailure {
            await finish(failure)
        } catch {
            await finish(ReceiveFailure(message: error.localizedDescription))
        }
    }

    nonisolated private struct ReceiveFailure: Error {
        let message: String
    }

    nonisolated private final class TerminalSink: Sendable {
        private let value = Mutex<(@Sendable (TerminalStreamMessage) -> Void)?>(nil)

        var handler: (@Sendable (TerminalStreamMessage) -> Void)? {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    private func route(_ envelope: Envelope, data: Data) {
        if let id = envelope.id {
            pendingRequests.removeValue(forKey: id)?.resume(returning: data)
        } else if envelope.method == MaidRPCMethod.terminalSubscribeList {
            // List updates are low-frequency lifecycle changes; decoding
            // inline keeps them ordered with the surrounding stream.
            if let onTerminalListItem,
               let notification = try? Self.listNotificationDecoder.decode(
                    TerminalListNotification.self, from: data) {
                onTerminalListItem(notification.params)
            }
        } else if let method = envelope.method {
            onNotification?(method, data)
        }
    }

    private static let listNotificationDecoder = WireJSON.makeDecoder()

    nonisolated private struct TerminalListNotification: Decodable {
        let params: TerminalListStreamItem
    }

    private func cancelRequest(_ id: Int) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    nonisolated private static func encodeInline<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func finishConnection(_ socket: URLSessionWebSocketTask, error: Error?) {
        guard webSocket === socket else { return }

        notifyTask?.cancel()
        notifyContinuation?.finish()
        notifyTask = nil
        notifyContinuation = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        receiveTask = nil
        let failure =
            error
            ?? RPCError("Connection closed")
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.resume(throwing: failure)
        }
        onDisconnect?(error)
    }

    nonisolated private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    nonisolated private struct NotificationRequest<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params
    }

    /// Terminal output notifications decode their payload in the same pass as
    /// the JSON-RPC route, avoiding a second parse of every output
    /// frame. Malformed terminal output fails the connection instead of being
    /// silently dropped, because one missing escape sequence can corrupt the
    /// rendered screen.
    nonisolated private struct Envelope: Decodable, Sendable {
        let id: Int?
        let method: String?
        let params: TerminalStreamMessage?

        private enum CodingKeys: String, CodingKey {
            case id, method, params
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int.self, forKey: .id)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            if method == MaidRPCMethod.terminalSubscribe {
                params = try container.decode(TerminalStreamMessage.self, forKey: .params)
            } else {
                params = nil
            }
        }
    }

    nonisolated private struct Response<Result: Decodable>: Decodable {
        let result: Result?
        let error: ErrorPayload?
    }

    nonisolated private struct ErrorResponse: Decodable {
        let error: ErrorPayload?
    }

    nonisolated private struct ErrorPayload: Decodable {
        let code: Int?
        let message: String
        let data: JSONAny?
    }
}
