import Foundation

final class MaidRPCClient {
    var onNotification: ((String, Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let endpoint: URL
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, any Error>] = [:]

    init(
        endpoint: URL = URL(string: "ws://127.0.0.1:8765/rpc")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
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
    }

    func disconnect() {
        guard let socket = webSocket else { return }
        finishConnection(socket, error: nil)
    }

    func call<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        let data = try await sendRequestAndWaitForResponse(method, params: params)
        let response = try newJSONDecoder().decode(Response<Result>.self, from: data)

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

    func callVoid<Params: Encodable>(_ method: String, params: Params) async throws {
        let data = try await sendRequestAndWaitForResponse(method, params: params)
        let response = try newJSONDecoder().decode(ErrorResponse.self, from: data)
        if let error = response.error {
            throw RPCError(code: error.code, message: error.message, data: error.data)
        }
    }

    private func sendRequestAndWaitForResponse<Params: Encodable>(
        _ method: String,
        params: Params
    ) async throws -> Data {
        guard let socket = webSocket else {
            throw RPCError(code: nil, message: "Not connected to maiD", data: nil)
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let request = Request(id: requestID, method: method, params: params)
        let requestData = try newJSONEncoder().encode(request)
        guard let requestText = String(data: requestData, encoding: .utf8) else {
            throw RPCError(
                code: nil,
                message: "Could not encode the JSON-RPC request",
                data: nil
            )
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

                try routeMessage(data)
            }
        } catch is CancellationError {
            finishConnection(socket, error: nil)
        } catch {
            finishConnection(socket, error: error)
        }
    }

    private func routeMessage(_ data: Data) throws {
        let route = try JSONDecoder().decode(Route.self, from: data)

        if let id = route.id {
            pendingRequests.removeValue(forKey: id)?.resume(returning: data)
        } else if let method = route.method {
            onNotification?(method, data)
        }
    }

    private func cancelRequest(_ id: Int) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finishConnection(_ socket: URLSessionWebSocketTask, error: Error?) {
        guard webSocket === socket else { return }

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

    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct Route: Decodable {
        let id: Int?
        let method: String?
    }

    private struct Response<Result: Decodable>: Decodable {
        let result: Result?
        let error: ErrorPayload?
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorPayload?
    }

    private struct ErrorPayload: Decodable {
        let code: Int?
        let message: String
        let data: JSONAny?
    }
}
