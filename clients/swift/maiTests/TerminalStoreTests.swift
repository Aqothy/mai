import Foundation
import Synchronization
import Testing

@testable import mai

@MainActor
struct TerminalStoreTests {
    private actor RestoreGate {
        private var didStart = false
        private var didFinish = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishWaiter: CheckedContinuation<Void, Never>?

        func restore() async {
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            guard !didFinish else { return }
            await withCheckedContinuation { finishWaiter = $0 }
        }

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func finish() {
            guard !didFinish else { return }
            didFinish = true
            let waiter = finishWaiter
            finishWaiter = nil
            waiter?.resume()
        }
    }

    final class FakeTerminalRPC: TerminalRPCClient {
        var onTerminalStreamItem: ((TerminalStreamMessage) -> Void)?
        var onTerminalListItem: ((TerminalListStreamItem) -> Void)?
        var onDisconnect: ((Error?) -> Void)?

        var connectCount = 0
        var disconnectCount = 0
        var listSubscribeCount = 0
        var created: [TerminalCreateParams] = []
        var attached: [TerminalAttachParams] = []
        var relaunched: [TerminalAttachParams] = []
        var detached: [TerminalDetachParams] = []
        var writes: [TerminalWriteParams] = []
        var resizes: [TerminalResizeParams] = []
        var renamed: [TerminalRenameParams] = []
        var terminated: [String] = []
        var deleted: [String] = []
        var deleteError: (any Error)?
        var listSnapshotTerminals: [TerminalSummary] = []
        var delaysListSnapshot = false
        private var pendingListSnapshots: [CheckedContinuation<TerminalListStreamItem, any Error>] = []
        private var pendingSnapshots: [CheckedContinuation<TerminalAttachSnapshot, any Error>] = []

        var pendingSnapshotCount: Int { pendingSnapshots.count }

        func connect() { connectCount += 1 }
        func disconnect() { disconnectCount += 1 }

        func subscribeTerminalList() async throws -> TerminalListStreamItem {
            listSubscribeCount += 1
            let snapshot = TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.snapshot.rawValue,
                terminal: nil,
                terminalID: nil,
                terminals: listSnapshotTerminals
            )
            guard delaysListSnapshot else { return snapshot }
            return try await withCheckedThrowingContinuation { continuation in
                pendingListSnapshots.append(continuation)
            }
        }

        func renameTerminal(_ params: TerminalRenameParams) async throws -> TerminalSummary {
            renamed.append(params)
            return TerminalSummary(
                agentActivity: nil,
                agentActivityUpdatedAt: nil,
                agentKind: nil,
                createdAt: Date(),
                cwd: "/tmp",
                exitCode: nil,
                observedTitle: nil,
                status: "running",
                terminalID: params.terminalID,
                title: params.title,
                updatedAt: Date()
            )
        }

        func deleteTerminal(terminalID: String) async throws {
            deleted.append(terminalID)
            if let deleteError { throw deleteError }
        }

        func emitList(_ item: TerminalListStreamItem) {
            onTerminalListItem?(item)
        }

        func respondToListSubscription() {
            guard !pendingListSnapshots.isEmpty else { return }
            pendingListSnapshots.removeFirst().resume(
                returning: TerminalListStreamItem(
                    kind: MaidTerminalListStreamItemKind.snapshot.rawValue,
                    terminal: nil,
                    terminalID: nil,
                    terminals: listSnapshotTerminals
                ))
        }

        func createTerminal(_ params: TerminalCreateParams) async throws -> TerminalAttachSnapshot {
            created.append(params)
            return try await nextSnapshot()
        }

        func attachTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
            attached.append(params)
            return try await nextSnapshot()
        }

        func relaunchTerminal(_ params: TerminalAttachParams) async throws -> TerminalAttachSnapshot {
            relaunched.append(params)
            return try await nextSnapshot()
        }

        func terminateTerminal(terminalID: String) async throws {
            terminated.append(terminalID)
        }

        func writeTerminal(_ params: TerminalWriteParams) { writes.append(params) }
        func resizeTerminal(_ params: TerminalResizeParams) { resizes.append(params) }
        func detachTerminal(_ params: TerminalDetachParams) { detached.append(params) }

        private func nextSnapshot() async throws -> TerminalAttachSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                pendingSnapshots.append(continuation)
            }
        }

        func respond(with snapshot: TerminalAttachSnapshot) {
            guard !pendingSnapshots.isEmpty else { return }
            pendingSnapshots.removeFirst().resume(returning: snapshot)
        }

        func failNext(_ message: String) {
            guard !pendingSnapshots.isEmpty else { return }
            pendingSnapshots.removeFirst()
                .resume(throwing: RPCError(code: nil, message: message, data: nil))
        }

        func emit(_ item: TerminalStreamMessage) {
            onTerminalStreamItem?(item)
        }
    }

    private static func snapshot(
        terminalID: String = "t1",
        runID: String = "run1",
        sequence: Int = 0,
        status: String = "running",
        exitCode: Int? = nil,
        snapshotData: Data = Data("snapshot".utf8),
        columns: Int = 80,
        rows: Int = 24
    ) -> TerminalAttachSnapshot {
        TerminalAttachSnapshot(
            columns: columns,
            rows: rows,
            runID: runID,
            sequence: sequence,
            snapshot: snapshotData.base64EncodedString(),
            snapshotFormat: TerminalSnapshotContract.format,
            terminal: TerminalSummary(
                agentActivity: nil,
                agentActivityUpdatedAt: nil,
                agentKind: nil,
                createdAt: Date(),
                cwd: "/tmp",
                exitCode: exitCode,
                observedTitle: nil,
                status: status,
                terminalID: terminalID,
                title: "",
                updatedAt: Date()
            )
        )
    }

    private static func statusItem(
        terminalID: String = "t1",
        runID: String = "run1",
        sequence: Int,
        status: String,
        exitCode: Int? = nil
    ) -> TerminalStreamMessage {
        TerminalStreamMessage(
            data: nil,
            exitCode: exitCode,
            kind: "status",
            message: nil,
            runID: runID,
            sequence: sequence,
            status: status,
            terminalID: terminalID
        )
    }

    private static func outputItem(
        data: Data,
        sequence: Int,
        runID: String = "run1"
    ) -> TerminalStreamMessage {
        TerminalStreamMessage(
            data: data,
            exitCode: nil,
            kind: "output",
            message: nil,
            runID: runID,
            sequence: sequence,
            status: nil,
            terminalID: "t1"
        )
    }

    private func waitForPhase(
        _ attachment: TerminalAttachment,
        _ phase: TerminalAttachment.Phase
    ) async {
        for _ in 0..<1000 where attachment.phase != phase {
            await Task.yield()
        }
        #expect(attachment.phase == phase)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    private func makeStore(
        rpc: FakeTerminalRPC,
        timing: RPCConnectionCoordinator.Timing = .immediate
    ) -> TerminalStore {
        TerminalStore(
            rpc: rpc,
            connection: RPCConnectionCoordinator(rpc: rpc, timing: timing),
            snapshotRestorer: { _, _ in }
        )
    }

    @Test func listUpdatesReceivedDuringSubscriptionReplayAfterSnapshot() async {
        let rpc = FakeTerminalRPC()
        rpc.delaysListSnapshot = true
        let store = makeStore(rpc: rpc)
        store.start()
        await waitFor { rpc.listSubscribeCount == 1 }

        let terminal = TerminalSummary(
            agentActivity: nil,
            agentActivityUpdatedAt: nil,
            agentKind: nil,
            createdAt: Date(),
            cwd: "/tmp",
            exitCode: nil,
            observedTitle: nil,
            status: "running",
            terminalID: "created-during-subscribe",
            title: "",
            updatedAt: Date()
        )
        rpc.emitList(
            TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.terminalUpserted.rawValue,
                terminal: terminal,
                terminalID: nil,
                terminals: nil
            ))
        #expect(store.terminals.isEmpty)

        rpc.respondToListSubscription()
        await waitFor { store.summary(for: terminal.terminalID) != nil }
        #expect(store.hasLoadedTerminalList)
    }

    /// Runs the store to a running attachment with one shared shortcut.
    private func runningAttachment(
        rpc: FakeTerminalRPC,
        store: TerminalStore,
        request: TerminalOpenRequest = .new(cwd: "", title: nil)
    ) async -> TerminalAttachment {
        store.start()
        let attachment = store.openTerminal(request)
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }
        rpc.respond(with: Self.snapshot())
        await waitForPhase(attachment, .running)
        return attachment
    }

    @Test func terminalStartsAtFirstMeasuredSurfaceGrid() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        await waitFor { rpc.connectCount == 1 }
        let attachment = store.openTerminal(.new(cwd: "/projects", title: nil))
        await Task.yield()
        #expect(rpc.created.isEmpty)

        attachment.gridChanged(columns: 92, rows: 31)
        await waitFor { rpc.created.count == 1 }
        #expect(rpc.created.first?.columns == 92)
        #expect(rpc.created.first?.rows == 31)
        #expect(rpc.created.first?.cwd == "/projects")

        // No corrective resize is needed when attach starts at the real grid.
        #expect(rpc.resizes.isEmpty)
        #expect(!attachment.hasInstalledInitialSnapshot)

        rpc.respond(with: Self.snapshot(columns: 92, rows: 31))
        await waitForPhase(attachment, .running)
        #expect(rpc.resizes.isEmpty)
        #expect(attachment.terminalID == "t1")
        #expect(attachment.hasInstalledInitialSnapshot)
    }

    @Test func synchronousInitialGridBurstUsesLatestGrid() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))

        attachment.gridChanged(columns: 32, rows: 11)
        attachment.gridChanged(columns: 39, rows: 35)
        await waitFor { rpc.created.count == 1 }

        #expect(rpc.created.count == 1)
        #expect(rpc.created.first?.columns == 39)
        #expect(rpc.created.first?.rows == 35)
    }

    @Test func attachModeAttachesToExistingTerminal() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t9"))
        #expect(attachment.terminalID == "t9")

        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.attached.count == 1 }
        #expect(rpc.attached.first?.terminalID == "t9")

        rpc.respond(with: Self.snapshot(terminalID: "t9", sequence: 41))
        await waitForPhase(attachment, .running)
        #expect(rpc.created.isEmpty)
    }

    /// A paint renders correctly only at the grid it was made for. When the
    /// surface grid moves while create/attach is in flight (iOS reports a
    /// provisional layout before settling), the stale snapshot is discarded
    /// and a fresh paint is fetched at the settled grid — never installed
    /// and patched with a resize.
    @Test func gridChangeDuringAttachRefetchesSnapshotAtSettledGrid() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))

        attachment.gridChanged(columns: 100, rows: 40)
        await waitFor { rpc.pendingSnapshotCount == 1 }
        attachment.gridChanged(columns: 80, rows: 28)
        #expect(rpc.resizes.isEmpty)

        // The response was painted at the requested 100x40; the surface has
        // since settled at 80x28, so the created run is joined again with a
        // plain attach at the settled grid.
        rpc.respond(with: Self.snapshot(terminalID: "t7", columns: 100, rows: 40))
        await waitFor { rpc.attached.count == 1 }
        #expect(attachment.phase == .attaching)
        #expect(rpc.attached.first?.terminalID == "t7")
        #expect(rpc.attached.first?.columns == 80)
        #expect(rpc.attached.first?.rows == 28)

        rpc.respond(with: Self.snapshot(terminalID: "t7", columns: 80, rows: 28))
        await waitForPhase(attachment, .running)
        #expect(rpc.resizes.isEmpty, "matching paint needs no follow-up resize")
    }

    /// A naturally exited run has no PTY, but the daemon can still reflow its
    /// retained Ghostty model. If layout moves while attach is in flight, the
    /// client fetches one correctly sized final snapshot instead of asking the
    /// surface to install a wrong-grid model.
    @Test func exitedSnapshotRefetchesAtSettledGrid() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t9"))

        attachment.gridChanged(columns: 100, rows: 40)
        await waitFor { rpc.pendingSnapshotCount == 1 }
        attachment.gridChanged(columns: 80, rows: 28)
        rpc.respond(
            with: Self.snapshot(terminalID: "t9", status: "exited", exitCode: 0, columns: 100, rows: 40))

        await waitFor { rpc.attached.count == 2 }
        #expect(rpc.attached.last?.columns == 80)
        #expect(rpc.attached.last?.rows == 28)
        rpc.respond(
            with: Self.snapshot(terminalID: "t9", status: "exited", exitCode: 0, columns: 80, rows: 28))
        await waitForPhase(attachment, .exited(0))
    }

    @Test func openingSameTerminalReusesAttachment() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let first = store.openTerminal(.existing(terminalID: "t1"))
        let again = store.openTerminal(.existing(terminalID: "t1"))
        #expect(first === again)
        #expect(rpc.detached.isEmpty)
    }

    @Test func openingAnotherTerminalDetachesTheFirst() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let first = await runningAttachment(rpc: rpc, store: store)

        let second = store.openTerminal(.existing(terminalID: "t2"))
        #expect(second !== first)
        #expect(rpc.detached.count == 1)
        #expect(rpc.detached.first?.terminalID == "t1")
        #expect(rpc.detached.first?.runID == "run1")

        // The replaced attachment no longer forwards input.
        first.sendInput(Data("x".utf8))
        #expect(rpc.writes.isEmpty)
    }

    @Test func itemsBufferedDuringAttachApplyAfterSnapshotInSequenceOrder() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }

        // Arrive while the create call is in flight, out of order, including
        // one at the snapshot sequence that must be discarded.
        rpc.emit(Self.statusItem(sequence: 7, status: "exited", exitCode: 3))
        rpc.emit(Self.statusItem(sequence: 5, status: "running"))
        #expect(attachment.phase == .attaching)

        rpc.respondToSnapshotSequenceFive()
        await waitForPhase(attachment, .exited(3))
    }

    @Test func snapshotInstallationIsTheVisibilityAndSequenceBarrier() async {
        let rpc = FakeTerminalRPC()
        let gate = RestoreGate()
        let store = TerminalStore(
            rpc: rpc,
            connection: RPCConnectionCoordinator(rpc: rpc, timing: .immediate),
            snapshotRestorer: { _, _ in await gate.restore() }
        )
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }

        rpc.respond(with: Self.snapshot(sequence: 5))
        await gate.waitUntilStarted()
        rpc.emit(Self.statusItem(sequence: 6, status: "exited", exitCode: 3))

        #expect(attachment.phase == .attaching)
        #expect(!attachment.hasInstalledInitialSnapshot)
        await gate.finish()
        await waitForPhase(attachment, .exited(3))
        #expect(attachment.hasInstalledInitialSnapshot)
    }

    @Test func incompatibleSnapshotFailsWithoutCallingGhostty() async {
        let rpc = FakeTerminalRPC()
        let restoreCalls = Mutex(0)
        let store = TerminalStore(
            rpc: rpc,
            connection: RPCConnectionCoordinator(rpc: rpc, timing: .immediate),
            snapshotRestorer: { _, _ in restoreCalls.withLock { $0 += 1 } }
        )
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }

        rpc.respond(with: Self.snapshot().with(snapshotFormat: "other-version"))
        await waitFor {
            if case .failed = attachment.phase { return true }
            return false
        }

        #expect(restoreCalls.withLock { $0 } == 0)
        #expect(rpc.detached.count == 1)
    }

    @Test func staleRunAndDuplicateSequenceItemsAreIgnored() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        rpc.emit(Self.statusItem(runID: "other-run", sequence: 9, status: "exited", exitCode: 1))
        #expect(attachment.phase == .running, "stale run items must not affect the current run")

        rpc.emit(Self.statusItem(sequence: 1, status: "exited", exitCode: 2))
        await waitForPhase(attachment, .exited(2))

        rpc.emit(Self.statusItem(sequence: 1, status: "exited", exitCode: 9))
        #expect(attachment.phase == .exited(2), "duplicate sequence must be dropped")
    }

    @Test func inputIsForwardedOnlyWhileRunning() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.new(cwd: "", title: nil))

        attachment.sendInput(Data("early".utf8))
        #expect(rpc.writes.isEmpty)

        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }
        rpc.respond(with: Self.snapshot())
        await waitForPhase(attachment, .running)

        attachment.sendInput(Data("ls\r".utf8))
        #expect(rpc.writes.count == 1)
        #expect(rpc.writes.first?.data == Data("ls\r".utf8).base64EncodedString())
        #expect(rpc.writes.first?.runID == "run1")

        rpc.emit(Self.statusItem(sequence: 1, status: "exited", exitCode: 0))
        await waitForPhase(attachment, .exited(0))
        attachment.sendInput(Data("late".utf8))
        #expect(rpc.writes.count == 1, "input after exit must not reach the daemon")
    }

    @Test func gridChangesAfterAttachForwardAsDedupedResize() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        attachment.gridChanged(columns: 120, rows: 40)
        #expect(rpc.resizes.count == 1)
        #expect(rpc.resizes.first?.columns == 120)
        #expect(rpc.resizes.first?.rows == 40)
        #expect(rpc.resizes.first?.runID == "run1")

        // Identical grid is not re-sent.
        attachment.gridChanged(columns: 120, rows: 40)
        #expect(rpc.resizes.count == 1)
    }

    @Test func changedGridsForwardWithoutAnAdditionalAppDebounce() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        attachment.gridChanged(columns: 100, rows: 30)
        attachment.gridChanged(columns: 110, rows: 34)
        attachment.gridChanged(columns: 120, rows: 40)

        #expect(rpc.resizes.map(\.columns) == [100, 110, 120])
        #expect(rpc.resizes.map(\.rows) == [30, 34, 40])
    }

    @Test func disconnectDisablesInputAndReconnectReattaches() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        rpc.onDisconnect?(nil)
        #expect(attachment.phase == .disconnected)
        #expect(attachment.controller.isInputEnabled == false)

        // The zero reconnect delay reconnects and reattaches automatically.
        await waitFor { rpc.connectCount == 2 && rpc.attached.count == 1 }
        #expect(rpc.attached.first?.terminalID == "t1")

        rpc.respond(with: Self.snapshot(sequence: 10))
        await waitForPhase(attachment, .running)
        #expect(attachment.controller.isInputEnabled)

        // Live output after the new snapshot sequence still applies.
        rpc.emit(Self.statusItem(sequence: 11, status: "exited", exitCode: 0))
        await waitForPhase(attachment, .exited(0))
    }

    @Test func relaunchAfterExitStartsFreshRun() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        rpc.emit(Self.statusItem(sequence: 1, status: "exited", exitCode: 0))
        await waitForPhase(attachment, .exited(0))

        let relaunched = store.relaunchActiveTerminal()
        #expect(relaunched != nil)
        #expect(relaunched !== attachment, "relaunch renders through a fresh session")
        relaunched?.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.relaunched.count == 1 }
        #expect(rpc.relaunched.first?.terminalID == "t1")

        rpc.respond(with: Self.snapshot(runID: "run2"))
        if let relaunched {
            await waitForPhase(relaunched, .running)
        }

        // Stale items from the old run cannot affect the new one.
        rpc.emit(Self.statusItem(runID: "run1", sequence: 99, status: "exited", exitCode: 1))
        #expect(relaunched?.phase == .running)
    }

    @Test func replacementRunSignalReattachesExistingListener() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        // Another attached client relaunched the shared terminal. A running
        // status for the new run tells this listener to fetch its snapshot.
        rpc.emit(Self.statusItem(runID: "run2", sequence: 0, status: "running"))
        await waitFor { rpc.attached.count == 1 }
        #expect(attachment.phase == .attaching)
        #expect(rpc.attached.first?.terminalID == "t1")

        rpc.respond(with: Self.snapshot(runID: "run2", sequence: 4))
        await waitForPhase(attachment, .running)
        #expect(attachment.runID == "run2")
    }

    @Test func closeAttachmentSendsDetachAndStopsForwarding() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        store.closeActiveTerminal()
        #expect(rpc.detached.count == 1)
        #expect(rpc.detached.first?.terminalID == "t1")
        #expect(rpc.detached.first?.runID == "run1")
        #expect(store.activeAttachment == nil)

        attachment.sendInput(Data("x".utf8))
        attachment.gridChanged(columns: 100, rows: 40)
        #expect(rpc.writes.isEmpty)
        #expect(rpc.resizes.isEmpty)
    }

    @Test func closingDuringAttachDetachesWhenTheSnapshotArrives() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t1"))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }

        store.closeActiveTerminal()
        #expect(store.activeAttachment == nil)
        #expect(rpc.detached.isEmpty)

        rpc.respond(with: Self.snapshot())
        await waitFor { rpc.detached.count == 1 }
        #expect(rpc.detached.first?.terminalID == "t1")
        #expect(rpc.detached.first?.runID == "run1")
    }

    @Test func canceledAttachCannotOverwriteItsReconnect() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t1"))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }

        rpc.onDisconnect?(nil)
        await waitFor { rpc.attached.count == 2 && rpc.pendingSnapshotCount == 2 }

        rpc.respond(with: Self.snapshot(runID: "stale-run"))
        await Task.yield()
        #expect(attachment.phase == .attaching)
        #expect(attachment.runID == nil)

        rpc.respond(with: Self.snapshot(runID: "current-run"))
        await waitForPhase(attachment, .running)
        #expect(attachment.runID == "current-run")
    }

    @Test func failedAttachReportsFailure() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t1"))
        attachment.gridChanged(columns: 80, rows: 24)
        await waitFor { rpc.pendingSnapshotCount == 1 }
        rpc.failNext("terminal is not running")
        await waitFor {
            if case .failed = attachment.phase { return true }
            return false
        }
    }

    @Test func streamMessageDecodesBase64Data() throws {
        let encoded = """
            {
              "data": "AAF/gA==",
              "kind": "output",
              "runId": "run1",
              "sequence": 1,
              "terminalId": "t1"
            }
            """

        let item = try JSONDecoder().decode(
            TerminalStreamMessage.self,
            from: Data(encoded.utf8)
        )

        #expect(item.data == Data([0x00, 0x01, 0x7F, 0x80]))
    }

    @Test func tenMiBNotificationBurstStaysOutsideObservation() async {
        let rpc = FakeTerminalRPC()
        let store = makeStore(rpc: rpc)
        let attachment = await runningAttachment(rpc: rpc, store: store)

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = attachment.phase
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        let chunkSize = 32 * 1_024
        let chunkCount = 10 * 1_024 * 1_024 / chunkSize
        let chunk = Data(repeating: 0x78, count: chunkSize)
        for sequence in 1...chunkCount {
            rpc.emit(Self.outputItem(data: chunk, sequence: sequence))
        }

        #expect(attachment.phase == .running)
        #expect(invalidated.withLock { $0 } == false)

        // A later sequence still applies, proving the entire burst advanced
        // the stream fence rather than being routed through observed state.
        rpc.emit(Self.statusItem(sequence: chunkCount + 1, status: "exited", exitCode: 0))
        await waitForPhase(attachment, .exited(0))
    }
}

extension TerminalStoreTests.FakeTerminalRPC {
    /// Responds with a snapshot whose sequence is 5, for the buffered-item
    /// ordering test: buffered sequence 5 must be discarded, 7 applied.
    func respondToSnapshotSequenceFive() {
        respond(
            with: TerminalAttachSnapshot(
                columns: 80,
                rows: 24,
                runID: "run1",
                sequence: 5,
                snapshot: Data("snapshot".utf8).base64EncodedString(),
                snapshotFormat: TerminalSnapshotContract.format,
                terminal: TerminalSummary(
                    agentActivity: nil,
                    agentActivityUpdatedAt: nil,
                    agentKind: nil,
                    createdAt: Date(),
                    cwd: "/tmp",
                    exitCode: nil,
                    observedTitle: nil,
                    status: "running",
                    terminalID: "t1",
                    title: "",
                    updatedAt: Date()
                )
            ))
    }
}
