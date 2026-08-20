import Foundation
import Synchronization
import Testing

@testable import mai

struct TerminalOutputPipelineTests {
    private static func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test func buffersOutputUntilFirstViewportThenFlushesInOrder() {
        let sunk = Mutex<[Data]>([])
        let pipeline = TerminalOutputPipeline(input: { _ in }, resize: { _ in })
        pipeline.bindSink { data in
            sunk.withLock { $0.append(data) }
        }

        pipeline.deliver(Self.data("a"))
        pipeline.deliver(Self.data("b"))
        #expect(sunk.withLock { $0 }.isEmpty, "output must not reach the sink before the surface exists")

        pipeline.handleViewport(columns: 80, rows: 24)
        #expect(sunk.withLock { $0 } == [Self.data("a"), Self.data("b")])

        pipeline.deliver(Self.data("c"))
        #expect(sunk.withLock { $0 } == [Self.data("a"), Self.data("b"), Self.data("c")])
    }

    @Test func resizeForwardsOnlyChangedGrids() {
        let grids = Mutex<[TerminalOutputPipeline.Grid]>([])
        let pipeline = TerminalOutputPipeline(
            input: { _ in },
            resize: { grid in grids.withLock { $0.append(grid) } }
        )

        pipeline.handleViewport(columns: 80, rows: 24)
        pipeline.handleViewport(columns: 80, rows: 24)
        #expect(grids.withLock { $0 } == [.init(columns: 80, rows: 24)])

        pipeline.handleViewport(columns: 120, rows: 24)
        #expect(grids.withLock { $0 }.count == 2)

        // Degenerate zero-sized reports never cross to the backend.
        pipeline.handleViewport(columns: 0, rows: 24)
        #expect(grids.withLock { $0 }.count == 2)
        #expect(pipeline.currentGrid == .init(columns: 120, rows: 24))
    }

    @Test func inputForwardingRespectsEnableGate() {
        let inputs = Mutex<[Data]>([])
        let pipeline = TerminalOutputPipeline(
            input: { data in inputs.withLock { $0.append(data) } },
            resize: { _ in }
        )

        pipeline.handleInput(Self.data("x"))
        #expect(inputs.withLock { $0 } == [Self.data("x")])

        pipeline.setInputEnabled(false)
        pipeline.handleInput(Self.data("y"))
        #expect(inputs.withLock { $0 } == [Self.data("x")])

        pipeline.setInputEnabled(true)
        pipeline.handleInput(Self.data("z"))
        #expect(inputs.withLock { $0 } == [Self.data("x"), Self.data("z")])
    }

    @Test func gridObserverSeesDeduplicatedChanges() {
        let observed = Mutex<[TerminalOutputPipeline.Grid]>([])
        let pipeline = TerminalOutputPipeline(input: { _ in }, resize: { _ in })
        pipeline.bindGridObserver { grid in
            observed.withLock { $0.append(grid) }
        }

        pipeline.handleViewport(columns: 80, rows: 24)
        pipeline.handleViewport(columns: 80, rows: 24)
        pipeline.handleViewport(columns: 80, rows: 30)
        #expect(observed.withLock { $0 } == [
            .init(columns: 80, rows: 24),
            .init(columns: 80, rows: 30),
        ])
    }

    @Test func deliverAfterSinkTargetReleasedIsSafe() {
        final class Target: Sendable {}
        var target: Target? = Target()
        let pipeline = TerminalOutputPipeline(input: { _ in }, resize: { _ in })
        pipeline.bindSink { [weak target] _ in
            _ = target
        }
        pipeline.handleViewport(columns: 80, rows: 24)
        target = nil
        pipeline.deliver(Self.data("late"))
    }

    @Test func tenMiBOutputBurstStaysOrderedAndComplete() {
        let chunkSize = 32 * 1_024
        let chunkCount = 10 * 1_024 * 1_024 / chunkSize
        let received = Mutex((chunks: 0, bytes: 0, orderIsValid: true))
        let pipeline = TerminalOutputPipeline(input: { _ in }, resize: { _ in })
        pipeline.bindSink { data in
            received.withLock { state in
                let expectedByte = UInt8(truncatingIfNeeded: state.chunks)
                state.orderIsValid = state.orderIsValid
                    && data.count == chunkSize
                    && data.allSatisfy { $0 == expectedByte }
                state.chunks += 1
                state.bytes += data.count
            }
        }
        pipeline.handleViewport(columns: 80, rows: 24)

        for index in 0..<chunkCount {
            pipeline.deliver(Data(repeating: UInt8(truncatingIfNeeded: index), count: chunkSize))
        }

        let result = received.withLock { $0 }
        #expect(result.chunks == chunkCount)
        #expect(result.bytes == 10 * 1_024 * 1_024)
        #expect(result.orderIsValid)
    }

}
