// UIKit-hosted coverage runs on iOS; the macOS text host has its own
// AppKit implementation exercised by the perf lab.
#if os(iOS)
import Foundation
import GhosttyTerminal
import Synchronization
import Testing
import UIKit

@testable import mai

@MainActor
struct TerminalSessionControllerTests {
    @Test func terminalUsesCodingKeyboardTraits() {
        let view = UITerminalView(frame: .zero)
        let textInputTraits: any UITextInputTraits = view

        #expect(view.inlinePredictionType == .no)
        #expect(textInputTraits.inlinePredictionType == .no)
        #expect(view.keyboardType == .default)
        #expect(textInputTraits.keyboardType == .default)
        #expect(view.tintColor == .clear)
        #expect(view.caretRect(for: view.beginningOfDocument).width == 0)
    }

    @Test func terminalPreservesMarkedTextForIMEComposition() {
        let view = UITerminalView(frame: .zero)

        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.markedTextRange != nil)
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        #expect(view.markedTextRange != nil)
        view.unmarkText()
        #expect(view.markedTextRange == nil)
    }

    @Test func softwareKeyboardInputUsesKeystrokeSemantics() {
        let context = TerminalPreviewBackend.makeContext()
        let viewState = context.controller.viewState
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
        rootViewController.view.layoutIfNeeded()

        view.insertText("l")
        view.insertText("s")
        let range = view.textRange(
            from: view.beginningOfDocument,
            to: view.endOfDocument
        )!
        view.replace(range, withText: "\n")

        #expect(
            context.backend.capturedInputs == [
                Data("l".utf8),
                Data("s".utf8),
                Data("\r".utf8),
            ])
        window.isHidden = true
    }

    @Test func accessoryAltPUsesGhosttyKeyboardProtocol() async {
        let backend = TerminalInputCaptureBackend()
        let controller = TerminalSessionController(backend: backend)
        let viewState = controller.viewState
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
        rootViewController.view.layoutIfNeeded()

        // Pi requests these Kitty keyboard flags before installing its
        // modified-key bindings. Accessory keys must use the same Ghostty key
        // path as hardware input so Alt-P remains distinguishable from the
        // legacy ESC-p sequence that Pi also treats as Alt-Up.
        controller.receive(Data("\u{1B}[>7u\u{1B}[?u".utf8))
        for _ in 0..<20 where backend.capturedInputs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let protocolResponse = backend.capturedInputs
            .reduce(into: Data()) { $0.append($1) }
        #expect(Array(protocolResponse) == Array(Data("\u{1B}[?7u".utf8)))
        let inputCount = backend.capturedInputs.count

        view.toggleStickyModifier(.alt)
        view.insertText("p")
        for _ in 0..<20 where backend.capturedInputs.count == inputCount {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let emitted = backend.capturedInputs.dropFirst(inputCount)
            .reduce(into: Data()) { $0.append($1) }
        #expect(Array(emitted) == Array(Data("\u{1B}[112;3u".utf8)))
        window.isHidden = true
    }

    @Test func surfaceRefitsWhenKeyboardChangesAvailableHeight() async {
        let context = TerminalPreviewBackend.makeContext()
        let viewState = context.controller.viewState
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        let rowsBeforeKeyboard = await settledRows(context.backend)

        view.frame.size.height = 400
        view.layoutIfNeeded()
        let rowsAfterKeyboard = await settledRows(context.backend)

        #expect(rowsBeforeKeyboard > 0)
        #expect(rowsAfterKeyboard < rowsBeforeKeyboard)
        window.isHidden = true
    }

    @Test func liveFontSizeChangePreservesTerminalModel() async {
        let context = TerminalPreviewBackend.makeContext()
        let viewState = context.controller.viewState
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()

        context.controller.receive(Data("MODEL SURVIVES FONT CHANGE".utf8))
        for _ in 0..<100
        where context.controller.session.readViewportText()?.contains("MODEL SURVIVES") != true {
            try? await Task.sleep(for: .milliseconds(5))
        }
        context.controller.setFontSize(TerminalSettings.defaultFontSize + 1)
        _ = await settledGrid(context.backend)

        #expect(
            context.controller.session.readViewportText()?.contains("MODEL SURVIVES FONT CHANGE")
                == true)
        window.isHidden = true
    }

    @Test func nativeSnapshotRestoresTheCompleteSurfaceModel() async throws {
        let context = TerminalPreviewBackend.makeContext()
        let viewState = context.controller.viewState
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.delegate = viewState
        view.controller = viewState.controller
        view.configuration = viewState.configuration

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        rootViewController.view.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()

        let target = TerminalOutputPipeline.Grid(
            columns: TerminalSnapshotFixture.columns,
            rows: TerminalSnapshotFixture.rows
        )
        let fittedGrid = await fit(view, to: target, backend: context.backend)
        #expect(fittedGrid == target)
        guard fittedGrid == target else {
            window.isHidden = true
            return
        }

        try await context.controller.restore(snapshot: TerminalSnapshotFixture.data)
        let viewport = context.controller.session.readViewportText()
        #expect(viewport?.contains("fixture history") == true)
        #expect(viewport?.contains("SNAPSHOT RESTORED") == true)
        #expect(viewport?.contains("prompt$") == true)
        window.isHidden = true
    }

    private func fit(
        _ view: UITerminalView,
        to target: TerminalOutputPipeline.Grid,
        backend: TerminalPreviewBackend
    ) async -> TerminalOutputPipeline.Grid? {
        for _ in 0..<12 {
            guard let current = await settledGrid(backend) else { return nil }
            if current == target { return current }
            view.frame.size = CGSize(
                width: view.frame.width * CGFloat(target.columns) / CGFloat(current.columns),
                height: view.frame.height * CGFloat(target.rows) / CGFloat(current.rows)
            )
            view.layoutIfNeeded()
        }
        return await settledGrid(backend)
    }

    @Test func inputStopsAfterInputDisabled() {
        let context = TerminalPreviewBackend.makeContext()

        context.controller.setInputEnabled(false)
        context.controller.session.sendInput(Data("x".utf8))
        #expect(context.backend.capturedInputs.isEmpty)
        #expect(context.controller.isInputEnabled == false)

        context.controller.setInputEnabled(true)
        context.controller.session.sendInput(Data("y".utf8))
        #expect(context.backend.capturedInputs == [Data("y".utf8)])
    }

    @Test func processEndDisablesInputAndMarksEnded() {
        let context = TerminalPreviewBackend.makeContext()

        context.controller.processDidEnd(exitCode: 0)

        #expect(context.controller.hasEnded)
        #expect(context.controller.isInputEnabled == false)
        context.controller.session.sendInput(Data("late".utf8))
        #expect(context.backend.capturedInputs.isEmpty)
    }

    @Test func rawOutputDoesNotInvalidateObservableState() {
        let context = TerminalPreviewBackend.makeContext()
        let invalidated = Mutex(false)

        withObservationTracking {
            _ = context.controller.hasEnded
            _ = context.controller.grid
            _ = context.controller.isInputEnabled
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        for _ in 0..<100 {
            context.controller.receive(Data("chunk of terminal output\r\n".utf8))
        }

        #expect(invalidated.withLock { $0 } == false)
    }

    private func settledRows(_ backend: TerminalPreviewBackend) async -> UInt16 {
        await settledGrid(backend)?.rows ?? 0
    }

    private func settledGrid(
        _ backend: TerminalPreviewBackend
    ) async -> TerminalOutputPipeline.Grid? {
        var previous = backend.capturedGrids.last
        var stableSamples = 0
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(5))
            let current = backend.capturedGrids.last
            if current != nil, current == previous {
                stableSamples += 1
                if stableSamples == 10 { return current }
            } else {
                previous = current
                stableSamples = 0
            }
        }
        return previous
    }

    @Test func teardownReleasesControllerAndSession() {
        weak var weakController: TerminalSessionController?
        weak var weakSession: AnyObject?

        do {
            let context = TerminalPreviewBackend.makeContext()
            weakController = context.controller
            weakSession = context.controller.session
        }

        #expect(weakController == nil)
        #expect(weakSession == nil)
    }
}

private nonisolated final class TerminalInputCaptureBackend: TerminalHostBackend {
    private let inputs = Mutex<[Data]>([])

    var capturedInputs: [Data] {
        inputs.withLock { $0 }
    }

    func sendInput(_ data: Data) {
        inputs.withLock { $0.append(data) }
    }

    func sendResize(columns _: UInt16, rows _: UInt16) {}
}

#endif
