import Foundation
import Testing

@testable import mai

@MainActor
struct WorkspaceListTests {
    private func summary(
        id: String,
        title: String = "",
        cwd: String = "/projects/app",
        status: String = "running",
        agentActivity: String? = nil,
        agentKind: String? = nil,
        observedTitle: String? = nil,
        updatedAt: Date
    ) -> TerminalSummary {
        TerminalSummary(
            agentActivity: agentActivity,
            agentActivityUpdatedAt: nil,
            agentKind: agentKind,
            createdAt: updatedAt,
            cwd: cwd,
            exitCode: nil,
            observedTitle: observedTitle,
            status: status,
            terminalID: id,
            title: title,
            updatedAt: updatedAt
        )
    }

    private func thread(id: String, title: String, updatedAt: Date) -> ThreadListEntry {
        ThreadListEntry(
            createdAt: updatedAt,
            cwd: "/projects/app",
            hasPendingApprovals: false,
            id: id,
            latestTurn: nil,
            modelSelection: nil,
            providerInstanceID: nil,
            session: nil,
            title: title,
            updatedAt: updatedAt
        )
    }

    private func makeTerminalStore(_ rpc: TerminalStoreTests.FakeTerminalRPC) -> TerminalStore {
        TerminalStore(
            rpc: rpc,
            connection: RPCConnectionCoordinator(rpc: rpc, timing: .immediate)
        )
    }

    @Test func mergedListOrdersByUpdatedAtWithStableTiebreak() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let items = WorkspaceListItem.merged(
            threads: [
                thread(id: "thread-b", title: "Older chat", updatedAt: base),
                thread(id: "thread-a", title: "Newest chat", updatedAt: base.addingTimeInterval(120)),
            ],
            terminals: [
                summary(id: "terminal-z", updatedAt: base.addingTimeInterval(60)),
                // Same timestamp as thread-b: id decides deterministically.
                summary(id: "terminal-a", updatedAt: base),
            ]
        )

        #expect(
            items.map(\.id) == [
                .agentThread("thread-a"),
                .terminal("terminal-z"),
                .terminal("terminal-a"),
                .agentThread("thread-b"),
            ])
    }

    @Test func listReducerAppliesSnapshotUpsertAndRemove() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        let store = makeTerminalStore(rpc)
        let base = Date(timeIntervalSince1970: 1_000_000)
        rpc.listSnapshotTerminals = [summary(id: "t1", updatedAt: base)]
        store.start()

        for _ in 0..<200 where !store.hasLoadedTerminalList {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.terminals.map(\.terminalID) == ["t1"])

        // Upsert of a newer terminal sorts it first.
        rpc.emitList(
            TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.terminalUpserted.rawValue,
                terminal: summary(id: "t2", title: "Newer", updatedAt: base.addingTimeInterval(60)),
                terminalID: nil,
                terminals: nil
            ))
        #expect(store.terminals.map(\.terminalID) == ["t2", "t1"])

        // Identical upsert does not replace row state.
        let before = store.terminals
        rpc.emitList(
            TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.terminalUpserted.rawValue,
                terminal: summary(id: "t2", title: "Newer", updatedAt: base.addingTimeInterval(60)),
                terminalID: nil,
                terminals: nil
            ))
        #expect(store.terminals == before)

        rpc.emitList(
            TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.terminalRemoved.rawValue,
                terminal: nil,
                terminalID: "t2",
                terminals: nil
            ))
        #expect(store.terminals.map(\.terminalID) == ["t1"])

        // Unknown future kinds are ignored without crashing.
        rpc.emitList(
            TerminalListStreamItem(
                kind: "future-kind",
                terminal: nil,
                terminalID: nil,
                terminals: nil
            ))
        #expect(store.terminals.map(\.terminalID) == ["t1"])
    }

    @Test func removalOfOpenTerminalClosesItsAttachment() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        let store = makeTerminalStore(rpc)
        store.start()
        for _ in 0..<200 where !store.hasLoadedTerminalList {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let attachment = store.openTerminal(.existing(terminalID: "t1"))
        attachment.gridChanged(columns: 80, rows: 24)

        rpc.emitList(
            TerminalListStreamItem(
                kind: MaidTerminalListStreamItemKind.terminalRemoved.rawValue,
                terminal: nil,
                terminalID: "t1",
                terminals: nil
            ))
        #expect(store.activeAttachment == nil)
    }

    @Test func terminalRowPresentationValues() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let untitled = summary(id: "t1", cwd: "/projects/maid", updatedAt: base)
        #expect(untitled.displayTitle == "maid")
        #expect(untitled.workingDirectoryName == "maid")
        #expect(untitled.statusLabel == "Running")
        #expect(untitled.rowIndicatorStatus == nil)
        #expect(untitled.isRunning)
        #expect(!untitled.needsRelaunchToOpen)

        let named = summary(id: "t2", title: "Build", status: "exited", updatedAt: base)
        #expect(named.displayTitle == "Build")
        #expect(named.statusLabel == "Exited")
        #expect(!named.needsRelaunchToOpen)

        let stopped = summary(id: "t3", status: "stopped", updatedAt: base)
        #expect(stopped.statusLabel == "Stopped")
        #expect(stopped.rowIndicatorStatus == .interrupted)
        #expect(stopped.needsRelaunchToOpen)

        let unknown = summary(id: "t4", status: "some-future-status", updatedAt: base)
        #expect(unknown.statusLabel == nil, "unknown statuses render neutrally")
        #expect(!unknown.needsRelaunchToOpen)
    }

    @Test func agentActivityStatusPriorityAndCopy() {
        let base = Date(timeIntervalSince1970: 1_000_000)

        let blocked = summary(id: "t1", agentActivity: "blocked", agentKind: "claude", updatedAt: base)
        #expect(blocked.statusLabel == "Needs input")
        #expect(blocked.rowIndicatorStatus == .needsInput)

        let done = summary(id: "t1", agentActivity: "done", agentKind: "codex", updatedAt: base)
        #expect(done.statusLabel == "Done")
        #expect(done.rowIndicatorStatus == .done)

        let working = summary(id: "t1", agentActivity: "working", agentKind: "claude", updatedAt: base)
        #expect(working.statusLabel == "Working")
        #expect(working.rowIndicatorStatus == .working)

        let idle = summary(id: "t1", agentActivity: "idle", agentKind: "codex", updatedAt: base)
        #expect(idle.statusLabel == "Agent ready")
        #expect(idle.rowIndicatorStatus == nil)

        // Unknown activity and future values fall back to the lifecycle label.
        #expect(summary(id: "t1", agentActivity: "unknown", updatedAt: base).statusLabel == "Running")
        #expect(summary(id: "t1", agentActivity: "future-activity", updatedAt: base).statusLabel == "Running")
        #expect(summary(id: "t1", agentActivity: "none", updatedAt: base).statusLabel == "Running")

        // Lifecycle wins when the terminal is not running.
        let exited = summary(id: "t1", status: "exited", agentActivity: "done", updatedAt: base)
        #expect(exited.statusLabel == "Exited")
        #expect(exited.rowIndicatorStatus == nil)

        let failed = summary(id: "t1", status: "error", updatedAt: base)
        #expect(failed.rowIndicatorStatus == .failed)
    }

    @Test func observedTitleDrivesSubtitle() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let plain = summary(id: "t1", cwd: "/projects/maid", updatedAt: base)
        #expect(plain.displaySubtitle == "maid")

        let observed = summary(
            id: "t1", cwd: "/projects/maid",
            observedTitle: "fix the reducer", updatedAt: base)
        #expect(observed.displaySubtitle == "fix the reducer")

        // A redundant observed title falls back to the folder name.
        let redundant = summary(
            id: "t1", title: "Build", cwd: "/projects/maid",
            observedTitle: "Build", updatedAt: base)
        #expect(redundant.displaySubtitle == "maid")
    }

    @Test func terminalSearchMatchesDisplayAndObservedTitlesButNotCwd() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let terminal = summary(
            id: "t1",
            title: "Build",
            cwd: "/projects/maid",
            observedTitle: "fix the reducer",
            updatedAt: base
        )

        var filter = ThreadListFilter(query: "build")
        #expect(filter.apply(toTerminals: [terminal]).map(\.terminalID) == ["t1"])

        filter.query = "reducer"
        #expect(filter.apply(toTerminals: [terminal]).map(\.terminalID) == ["t1"])

        filter.query = "projects"
        #expect(filter.apply(toTerminals: [terminal]).isEmpty)
    }

    @Test func identicalAgentReportsCompareEqual() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = summary(id: "t1", agentActivity: "working", agentKind: "claude", observedTitle: "task", updatedAt: base)
        let b = summary(id: "t1", agentActivity: "working", agentKind: "claude", observedTitle: "task", updatedAt: base)
        #expect(a == b, "identical detector reports must not replace row state")

        let changed = summary(id: "t1", agentActivity: "blocked", agentKind: "claude", observedTitle: "task", updatedAt: base)
        #expect(a != changed)
    }

    @Test func openingStoppedTerminalRelaunches() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        let store = makeTerminalStore(rpc)
        rpc.listSnapshotTerminals = [
            summary(id: "t1", status: "stopped", updatedAt: Date())
        ]
        store.start()
        for _ in 0..<200 where !store.hasLoadedTerminalList {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let attachment = store.openTerminal(.existing(terminalID: "t1"))
        attachment.gridChanged(columns: 80, rows: 24)
        for _ in 0..<200 where rpc.relaunched.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(rpc.relaunched.map(\.terminalID) == ["t1"])
        #expect(rpc.attached.isEmpty)
    }

    @Test func renameAppliesReturnedSummary() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        let store = makeTerminalStore(rpc)
        store.start()

        store.renameTerminal(terminalID: "t1", title: "Renamed")
        for _ in 0..<200 where rpc.renamed.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<200 where store.summary(for: "t1") == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.summary(for: "t1")?.title == "Renamed")
    }

    @Test func deleteClosesAttachmentAndCallsDaemon() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        let store = makeTerminalStore(rpc)
        store.start()
        _ = store.openTerminal(.existing(terminalID: "t1"))

        try? await store.deleteTerminal(terminalID: "t1")
        #expect(store.activeAttachment == nil)
        #expect(rpc.deleted == ["t1"])
    }

    @Test func failedDeleteKeepsAttachmentOpen() async {
        let rpc = TerminalStoreTests.FakeTerminalRPC()
        rpc.deleteError = RPCError(code: nil, message: "delete failed", data: nil)
        let store = makeTerminalStore(rpc)
        store.start()
        let attachment = store.openTerminal(.existing(terminalID: "t1"))

        do {
            try await store.deleteTerminal(terminalID: "t1")
            Issue.record("delete unexpectedly succeeded")
        } catch {}
        #expect(store.activeAttachment === attachment)
    }
}
