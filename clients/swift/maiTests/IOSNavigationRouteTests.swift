#if os(iOS)
import Testing

@testable import mai

struct IOSNavigationRouteTests {
    @Test func selectedThreadIDTracksOnlyTopmostThreadRoute() {
        #expect(IOSNavigationRoute.selectedThreadID(in: []) == nil)
        #expect(IOSNavigationRoute.selectedThreadID(in: [.thread("t1")]) == "t1")
        #expect(IOSNavigationRoute.selectedThreadID(in: [.thread("t1"), .thread("t2")]) == "t2")
        #expect(IOSNavigationRoute.selectedThreadID(in: [.thread("t1"), .newChat(workingDirectory: nil)]) == nil)
        #expect(IOSNavigationRoute.selectedThreadID(in: [.agentRegistry]) == nil)
        #expect(IOSNavigationRoute.selectedThreadID(in: [.sessionImport]) == nil)
    }

    @MainActor
    @Test func rapidPopAndRepushOfSameThreadKeepsThreadSelected() {
        let thread = ChatSyntheticBenchmarkThread.thread(turnCount: 2)
        let store = ThreadStore(previewThreads: [thread.summary], selectedThread: thread)
        var path: [IOSNavigationRoute] = [.thread(thread.id)]

        func syncSelection() {
            let target = IOSNavigationRoute.selectedThreadID(in: path)
            if store.selectedThreadID != target {
                store.selectThread(target)
            }
        }

        syncSelection()
        #expect(store.selectedThreadID == thread.id)

        // Swipe back pops the route; selection clears immediately.
        path = []
        syncSelection()
        #expect(store.selectedThreadID == nil)

        // Immediately tapping the same thread selects it and pushes again.
        store.selectThread(thread.id)
        path = [.thread(thread.id)]
        syncSelection()
        #expect(store.selectedThreadID == thread.id)
    }
}
#endif
