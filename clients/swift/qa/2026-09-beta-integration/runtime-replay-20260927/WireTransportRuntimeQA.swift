import Foundation
import Testing
@testable import mai

// Copy into maiTests for a supervised run, replacing QA_ENDPOINT with the
// loopback endpoint printed by date-wire-server.go. Remove after the run.
struct WireTransportRuntimeQA {
    @Test @MainActor
    func actualRPCResponseAndTerminalNotificationsDecodeDaemonDates() async throws {
        struct Params: Encodable {}
        struct Ack: Decodable { let ok: Bool }
        let endpoint = try #require(URL(string: "QA_ENDPOINT"))
        let client = RPCClient(endpoint: endpoint)
        var items: [TerminalListStreamItem] = []
        client.onTerminalStreamItem = { _ in }
        client.onTerminalListItem = { items.append($0) }
        client.connect()
        defer { client.disconnect() }
        print("WIRE_TRANSPORT_RUNTIME \(ProcessInfo.processInfo.operatingSystemVersionString) simulator=\(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "none") endpoint=\(endpoint)")
        let thread = try await client.call("qa.thread", params: Params(), as: mai.Thread.self)
        #expect(abs(thread.createdAt.timeIntervalSince1970 - 1_790_224_001.437657) < 0.000001)
        let ack = try await client.call("qa.terminal", params: Params(), as: Ack.self)
        #expect(ack.ok)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while items.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(items.count == 2)
        for (item, expected) in zip(items, [1_790_224_001.437657, 1_790_224_002]) {
            let terminal = try #require(item.terminal)
            #expect(terminal.terminalID == "wire-date-qa")
            #expect(abs(terminal.createdAt.timeIntervalSince1970 - expected) < 0.000001)
            #expect(terminal.updatedAt == terminal.createdAt)
            #expect(terminal.agentActivityUpdatedAt == terminal.createdAt)
        }
    }
}
