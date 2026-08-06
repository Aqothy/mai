#if DEBUG
import Foundation
import Synchronization

/// Fake host backend for previews and tests. It echoes typed input back to
/// the renderer, records everything it receives, and prints a canned ANSI
/// banner once the surface reports its first grid — no daemon involved.
nonisolated final class TerminalPreviewBackend: TerminalHostBackend {
    @MainActor
    struct Context {
        let controller: TerminalSessionController
        let backend: TerminalPreviewBackend
    }

    private struct State {
        var output: (@Sendable (Data) -> Void)?
        var sentBanner = false
        var inputs: [Data] = []
        var grids: [TerminalOutputPipeline.Grid] = []
    }

    private let state = Mutex(State())

    /// Builds a fully wired controller/backend pair for previews and tests.
    @MainActor
    static func makeContext() -> Context {
        let backend = TerminalPreviewBackend()
        let controller = TerminalSessionController(backend: backend)
        backend.bindOutput { [weak controller] data in
            controller?.receive(data)
        }
        return Context(controller: controller, backend: backend)
    }

    /// Connects the byte path back into the renderer.
    func bindOutput(_ output: @escaping @Sendable (Data) -> Void) {
        state.withLock { $0.output = output }
    }

    var capturedInputs: [Data] {
        state.withLock { $0.inputs }
    }

    var capturedGrids: [TerminalOutputPipeline.Grid] {
        state.withLock { $0.grids }
    }

    func sendInput(_ data: Data) {
        let output = state.withLock { state in
            state.inputs.append(data)
            return state.output
        }
        // Local echo so typing is visible without a shell: CR becomes CRLF.
        var echoed = Data(capacity: data.count + 1)
        for byte in data {
            if byte == 0x0D {
                echoed.append(contentsOf: [0x0D, 0x0A])
            } else {
                echoed.append(byte)
            }
        }
        output?(echoed)
    }

    func sendResize(columns: UInt16, rows: UInt16) {
        let (output, firstReport) = state.withLock { state in
            state.grids.append(.init(columns: columns, rows: rows))
            let first = !state.sentBanner
            state.sentBanner = true
            return (state.output, first)
        }
        guard let output else { return }
        if firstReport {
            output(Data(Self.banner.utf8))
        }
        output(Data("\r\n\u{1B}[2mgrid \(columns)x\(rows)\u{1B}[0m\r\n\u{1B}[32m❯\u{1B}[0m ".utf8))
    }

    private static let banner: String = {
        var lines: [String] = []
        lines.append("\u{1B}[1;36mmaiD terminal preview\u{1B}[0m")
        lines.append("fake host-managed backend; input is echoed locally")
        let swatches = (0...7)
            .map { "\u{1B}[4\($0)m  \u{1B}[0m" }
            .joined()
        lines.append(swatches)
        lines.append("\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m \u{1B}[7minverse\u{1B}[0m")
        return lines.joined(separator: "\r\n")
    }()
}
#endif
