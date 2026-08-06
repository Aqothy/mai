import Foundation

final class RPCClient {
    private static let notificationQueueLimit = 1_024

    var onNotification: ((String, Data) -> Void)?
    var onTerminalStreamItem: ((TerminalStreamMessage) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let endpoint: URL
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var notifyContinuation: AsyncStream<String>.Continuation?
    private var notifyTask: Task<Void, Never>?

    init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint ?? RPCClient.configuredEndpoint
        self.session = session
    }

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

        let socket = session.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 64 * 1_024 * 1_024
        webSocket = socket
        socket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: socket)
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

    func call<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: sending Params,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        let data = try await sendRequestAndWaitForResponse(method, params: params)
        let response = try await Self.decode(Response<Result>.self, from: data)

        if let error = response.error {
            throw RPCError(code: error.code, message: error.message, data: error.data)
        }
        guard let result = response.result else {
            throw RPCError(
                code: nil,
                message: "maiD returned no result for \(method)",
                data: nil
            )
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
                error: RPCError(
                    code: nil,
                    message: "Client notification queue is full",
                    data: nil
                )
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    // Encoding runs off the main actor for the same reason decoding does: a
    // thread.turn.start with base64 image/audio attachments is a multi-MB
    // JSON body, and escaping it inline in the send path is a visible hitch.
    @concurrent
    private static func encode<Value: Encodable & SendableMetatype>(
        _ value: sending Value
    ) async throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RPCError(
                code: nil,
                message: "Could not encode the JSON-RPC request",
                data: nil
            )
        }
        return text
    }

    private func sendRequestAndWaitForResponse<Params: Encodable>(
        _ method: String,
        params: sending Params
    ) async throws -> Data {
        guard webSocket != nil else {
            throw RPCError(code: nil, message: "Not connected to maiD", data: nil)
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let requestText = try await Self.encode(
            Request(id: requestID, method: method, params: params)
        )
        guard let socket = webSocket else {
            throw RPCError(code: nil, message: "Not connected to maiD", data: nil)
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

    private func receiveMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data

                switch message {
                case .string(let text):
                    guard let textData = text.data(using: .utf8) else {
                        throw RPCError(
                            code: nil,
                            message: "maiD sent invalid UTF-8",
                            data: nil
                        )
                    }
                    data = textData
                case .data:
                    throw RPCError(
                        code: nil,
                        message: "maiD sent a binary WebSocket frame",
                        data: nil
                    )
                @unknown default:
                    throw RPCError(
                        code: nil,
                        message: "maiD sent an unknown WebSocket frame",
                        data: nil
                    )
                }

                if onTerminalStreamItem != nil {
                    let envelope = try await Self.decode(TerminalEnvelope.self, from: data)
                    routeTerminalEnvelope(envelope, data: data)
                } else {
                    let route = try await Self.decode(Route.self, from: data)
                    routeMessage(route, data: data)
                }
            }
        } catch is CancellationError {
            finishConnection(socket, error: nil)
        } catch {
            finishConnection(socket, error: error)
        }
    }

    private func routeMessage(_ route: Route, data: Data) {
        if let id = route.id {
            pendingRequests.removeValue(forKey: id)?.resume(returning: data)
        } else if let method = route.method {
            onNotification?(method, data)
        }
    }

    private func routeTerminalEnvelope(_ envelope: TerminalEnvelope, data: Data) {
        if let id = envelope.id {
            pendingRequests.removeValue(forKey: id)?.resume(returning: data)
        } else if envelope.method == MaidRPCMethod.terminalSubscribe,
                  let item = envelope.params {
            onTerminalStreamItem?(item)
        } else if let method = envelope.method {
            onNotification?(method, data)
        }
    }

    private func cancelRequest(_ id: Int) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    nonisolated private static func encodeInline<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RPCError(
                code: nil,
                message: "Could not encode the JSON-RPC notification",
                data: nil
            )
        }
        return text
    }

    private func finishConnection(_ socket: URLSessionWebSocketTask, error: Error?) {
        guard webSocket === socket else { return }

        notifyTask?.cancel()
        notifyContinuation?.finish()
        notifyTask = nil
        notifyContinuation = nil
        receiveTask?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        receiveTask = nil
        let failure =
            error
            ?? RPCError(
                code: nil,
                message: "Connection closed",
                data: nil
            )
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

    nonisolated private struct Route: Decodable {
        let id: Int?
        let method: String?
    }

    /// Terminal connections decode their notification payload in the same
    /// pass as the JSON-RPC route, avoiding a second parse of every output
    /// frame. Malformed terminal output fails the connection instead of being
    /// silently dropped, because one missing escape sequence can corrupt the
    /// rendered screen.
    nonisolated private struct TerminalEnvelope: Decodable, Sendable {
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
