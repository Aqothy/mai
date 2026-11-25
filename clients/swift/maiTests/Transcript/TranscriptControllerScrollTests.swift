import CoreGraphics
import Foundation
import QuartzCore
import Synchronization
import Testing
#if os(iOS)
    import UIKit
#endif

@testable import mai

/// PLAN 3.9: the controller owns the follow state, the reading place and
/// every viewport move. Cases from `ChatIOSNativeTranscriptTests`,
/// `ChatMacScrollPositionPreserverTests`, `ChatNativeTranscriptTests` and
/// `ChatVirtualTranscriptGeometryTests`, against a viewport with UIKit's
/// semantics (the Mac document has its own tests).
@MainActor
struct TranscriptControllerScrollTests {
    private func make(
        size: CGSize = CGSize(width: 300, height: 200)
    ) -> (TranscriptController, FakeTranscriptHost) {
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = size
        host.controller = controller
        controller.attach(host)
        return (controller, host)
    }

    private func rows(_ ids: [String], sources: [String]? = nil) -> [TranscriptRow] {
        zip(ids, sources ?? ids).map { id, source in
            TranscriptRow(id: id, sourceID: source, kind: .notice(title: id, text: nil))
        }
    }

    private func uniform(_ ids: [String], _ height: CGFloat) -> [String: CGFloat] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, height) })
    }

    private let tenRows = (0..<10).map { "row-\($0)" }

    // MARK: Rule 4: every geometry change keeps the reading place

    @Test func readingPositionHoldsThroughHeightChangeAboveAndPrepend() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 350)

        // The first row grows above the viewport; the row being read keeps
        // its place on screen, in the same pass.
        controller.setHeights(["row-0": 200])
        #expect(host.viewportTop == 450)

        // An older page arrives above every row.
        controller.setRows(
            rows(["older-a", "older-b"] + tenRows),
            measuredHeights: ["older-a": 20, "older-b": 50])
        #expect(host.viewportTop == 520)
    }

    @Test func followingKeepsTheEndInViewWhileAReplyGrows() {
        let (controller, host) = make()
        controller.setRows(
            rows(["reply", "working", "end"]),
            measuredHeights: ["reply": 600, "working": 20, "end": 1])
        #expect(host.viewportTop == host.documentHeight - 200)
        for height in [CGFloat(630), 950, 780, 1100] {
            controller.setHeights(["reply": height])
            #expect(host.viewportTop == host.documentHeight - 200)
            #expect(controller.isEndVisible)
        }
    }

    /// A streaming reply's live row becomes its final blocks while the
    /// reader is inside it, and the working row below it leaves.
    @Test func aReaderInsideASettlingReplyKeepsTheirPlaceInIt() {
        let (controller, host) = make()
        controller.setRows(
            rows(["user", "message-m", "working", "end"], sources: ["user", "m", "working", "end"]),
            measuredHeights: ["user": 100, "message-m": 900, "working": 40, "end": 1])
        host.readerScroll(toTop: 600)

        controller.setRows(
            rows(["user", "m#0", "m#1", "end"], sources: ["user", "m", "m", "end"]),
            measuredHeights: ["user": 100, "m#0": 400, "m#1": 500, "end": 1])
        #expect(host.viewportTop == 600)
    }

    /// The work the reader was looking at folds behind its header when the
    /// turn finishes.
    @Test func aReaderInsideFoldedWorkLandsBelowTheHeader() {
        let (controller, host) = make()
        controller.setRows(
            rows(["user", "header", "work-a", "work-b", "reply"]),
            measuredHeights: ["user": 100, "header": 40, "work-a": 300, "work-b": 300, "reply": 900])
        host.readerScroll(toTop: 500)

        controller.setRows(
            rows(["user", "header", "reply"]),
            measuredHeights: ["user": 100, "header": 40, "reply": 900])
        #expect(host.viewportTop == 140)
    }

    @Test func remeasurementDuringReaderScrollingKeepsTheReadersNewPosition() {
        let ids = (0..<12).map { "row-\($0)" }
        let (controller, host) = make()
        controller.setRows(rows(ids), measuredHeights: uniform(ids, 100))
        host.readerScroll(toTop: 250)

        controller.setHeights(["row-0": 200])
        host.readerScroll(toTop: 700)
        #expect(host.viewportTop == 700)

        // Where the reader scrolled is the place later layout keeps.
        controller.setHeights(["row-0": 250])
        #expect(host.viewportTop == 750)
    }

    @Test func reflowPreservesTheReadingPositionEvenWhenTotalHeightIsUnchanged() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 250)
        controller.setHeights(["row-0": 200, "row-1": 50, "row-2": 50])
        #expect(host.documentHeight == 1_000)
        #expect(host.viewportTop == 300)
    }

    // MARK: Rules 1 and 2: only the reader's moves are intent

    /// Offset changes the reader makes, by any input, are intent; the
    /// controller's own, and the platform's inside its setters, are not.
    @Test func onlyTheReadersOwnScrollsCountAsIntent() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        controller.debugReaderMoves.removeAll()

        host.readerScroll(toTop: 500)
        host.readerScroll(toTop: 300)
        host.readerScroll(toTop: 600)
        host.readerScroll(toTop: 800)
        #expect(controller.debugReaderMoves == [.awayFromEnd, .awayFromEnd, .awayFromEnd, .reachedEnd])
        #expect(controller.isFollowing)

        controller.setHeights(["row-0": 200])
        #expect(host.viewportTop == 900)
        #expect(controller.debugReaderMoves.count == 4)
    }

    /// A slow scroll moves less than the threshold each step; the steps add
    /// up until they count.
    @Test func smallStepsAccumulateUntilTheyCount() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 799.7)
        #expect(controller.isFollowing)
        host.readerScroll(toTop: 799.4)
        #expect(!controller.isFollowing)
    }

    @Test func overscrollPastTheEndIsNoMove() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 860)
        host.readerScroll(toTop: 800)
        #expect(controller.isFollowing)
        #expect(controller.debugReaderMoves.isEmpty)
    }

    // MARK: Rule 3: a viewport change is never the reader's

    @Test func resizingIsNotAReaderMove() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 350)
        controller.debugReaderMoves.removeAll()

        host.resize(to: CGSize(width: 270, height: 150))
        #expect(host.viewportTop == 350)
        #expect(controller.debugReaderMoves.isEmpty)
        #expect(!controller.isFollowing)
    }

    @Test func resizingWhileFollowingLandsOnTheEnd() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.resize(to: CGSize(width: 300, height: 150))
        #expect(host.viewportTop == 850)
        host.resize(to: CGSize(width: 300, height: 400))
        #expect(host.viewportTop == 600)
        #expect(controller.isFollowing)
    }

    /// A keyboard closing while the reader is at the end must not leave
    /// blank space below the last row.
    @Test func shrinkingInsetsPullTheViewportBackInsideTheContent() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.setInsets(top: 0, bottom: 300)
        host.readerScroll(toOffset: 1_100)
        host.setInsets(top: 0, bottom: 0)
        #expect(host.offset == 800)
        #expect(controller.isFollowing)
    }

    /// Opening the keyboard while within the 24 pt near-bottom zone pushes the
    /// chat up even if a tiny upward finger-lift wiggle stopped `isFollowing`;
    /// scrolled further up in history, the keyboard overlays without jumping.
    @Test func keyboardOpeningPinsNearBottomEvenAfterTinyLiftWiggle() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        // Tiny 2 pt upward wiggle inside the 24 pt near-bottom zone flips
        // `isFollowing` off while `isEndVisible` stays true.
        host.readerScroll(toTop: 798)
        #expect(!controller.isFollowing)
        #expect(controller.isEndVisible)
        host.setInsets(top: 0, bottom: 100)
        #expect(host.viewportTop == 900)

        // Reset insets and scroll well into history (> 24 pt away from end):
        // opening the keyboard must keep the reader's position instead of jumping.
        host.setInsets(top: 0, bottom: 0)
        host.readerScroll(toTop: 300)
        host.setInsets(top: 0, bottom: 100)
        #expect(host.viewportTop == 300)
    }

    /// Bounded-budget sync fallback prepares normal-sized visible blank rows
    /// synchronously within the deadline while leaving giant (> 8 KB) rows
    /// strictly off the main thread.
    @Test func syncFallbackPreparesNormalVisibleRowsAndSkipsGiantRows() {
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 400, height: 300)
        host.controller = controller
        controller.attach(host)

        let smallMessage = TranscriptMessage(kind: .assistant, turnID: "t", ref: "small")
        let giantMessage = TranscriptMessage(kind: .assistant, turnID: "t", ref: "giant")
        let smallPending = smallMessage.pendingRow(source: "Short reply paragraph.")
        let giantPending = giantMessage.pendingRow(source: String(repeating: "word ", count: 30_000))
        let tail = TranscriptRow(
            id: "tail", sourceID: "tail", kind: .userMessage([.paragraph([MarkdownInline(text: "End")])]))
        controller.setRows(
            [smallPending, giantPending, tail],
            measuredHeights: [smallPending.id: 40, giantPending.id: 100, "tail": 40])
        controller.storeLayout(RowLayoutBuilder.layout(controller.request(controller.rows[2])))
        // Simulate already-revealed state at top of transcript.
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(-5))
        controller.alignInitialEndIfPossible()
        #expect(!controller.isAwaitingInitialEnd)
        host.readerScroll(toTop: 0)

        controller.prepareVisibleSynchronously(
            in: CGRect(x: 0, y: 0, width: 400, height: 300), deadline: CACurrentMediaTime() + 0.05)
        // Small visible pending row parsed and laid out synchronously.
        #expect(controller.rows.contains { $0.id == "\(smallMessage.id)#0" })
        #expect(controller.layouts["\(smallMessage.id)#0"] != nil)
        // Giant > 128 KB pending row stayed untouched for off-main LayoutQueue.
        #expect(controller.rows.contains { $0.id == giantPending.id })

        // A large Markdown table (metrics.bytes == 0, > 64 cells) must also be
        // skipped by synchronous fallback, and rows under `topInset` must not
        // be skipped by step 2's raw-rect conversion.
        let header = (0..<4).map { [MarkdownInline(text: "H\($0)")] }
        let tableRows = (0..<40).map { r in (0..<4).map { c in [MarkdownInline(text: "r\(r)c\(c)")] } }
        let bigTable = TranscriptRow(
            id: "big-table", sourceID: "big-table",
            kind: .markdownBlock(
                .table(MarkdownTable(alignments: [.leading, .leading, .leading, .leading], header: header, rows: tableRows)),
                .single))
        let underNav = TranscriptRow(
            id: "under-nav", sourceID: "under-nav",
            kind: .markdownBlock(.paragraph([MarkdownInline(text: "Visible under nav bar")]), .single))
        host.setInsets(top: 60, bottom: 0)
        controller.setRows([underNav, bigTable], measuredHeights: ["under-nav": 40, "big-table": 400])
        host.readerScroll(toOffset: 0)
        controller.prepareVisibleSynchronously(
            in: CGRect(x: 0, y: 0, width: 400, height: 300), deadline: CACurrentMediaTime() + 0.05)
        #expect(controller.layouts["under-nav"] != nil)
        #expect(controller.layouts["big-table"] == nil)
    }

    // MARK: Rule 5: end visibility from the same pass

    @Test func endVisibilityIsCurrentAfterEveryPass() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        #expect(controller.isEndVisible)
        host.readerScroll(toTop: 300)
        #expect(!controller.isEndVisible)
        host.readerScroll(toTop: 780)
        #expect(controller.isEndVisible)
    }

    // MARK: Rule 6: expanding and collapsing

    @Test func expandingStopsFollowingWhenTheEndLeavesTheViewport() {
        let (controller, host) = make()
        controller.setRows(
            rows(["user", "header", "reply"]),
            measuredHeights: ["user": 100, "header": 50, "reply": 100])
        #expect(host.viewportTop == 50)
        controller.noteExpansion()
        controller.setRows(
            rows(["user", "header", "work", "reply"]),
            measuredHeights: ["work": 300])
        #expect(host.viewportTop == 50)
        #expect(!controller.isFollowing)
        controller.setHeights(["reply": 140])
        #expect(host.viewportTop == 50)
    }

    @Test func expandingResumesFollowingWhenTheEndStaysVisible() {
        let (controller, host) = make()
        controller.setRows(
            rows(["user", "header", "reply"]),
            measuredHeights: ["user": 100, "header": 50, "reply": 250])
        #expect(host.viewportTop == 200)
        controller.noteExpansion()
        controller.setRows(
            rows(["user", "header", "work", "reply"]),
            measuredHeights: ["work": 300])
        // The reader keeps reading the reply, which still ends the transcript.
        #expect(host.viewportTop == 500)
        #expect(controller.isFollowing)
    }

    // MARK: Rule 7: jumping to the end

    @Test func aJumpLandsOnTheEndAndFollows() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 300)
        controller.jumpToEnd(animated: false)
        #expect(host.viewportTop == 800)
        #expect(controller.isFollowing)
        controller.setHeights(["row-9": 300])
        #expect(host.viewportTop == 1_000)
    }

    // MARK: Rule 9: opening

    @Test func theTranscriptStaysHiddenUntilItsFirstRowsLandOnTheEnd() {
        let (controller, host) = make()
        #expect(!host.isContentVisible)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        #expect(host.viewportTop == 800)
        #expect(host.isContentVisible)
    }

    @Test func aViewportArrivingAfterTheRowsStillLandsOnTheEnd() {
        let controller = TranscriptController(configuration: .testing)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        let host = FakeTranscriptHost()
        host.controller = controller
        controller.attach(host)
        #expect(host.viewportTop == 800)
        #expect(host.isContentVisible)
    }

    @Test func aChatShownAgainKeepsItsPlace() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 300)
        controller.detach(host)

        let again = FakeTranscriptHost()
        again.controller = controller
        controller.attach(again)
        #expect(again.viewportTop == 300)
        #expect(again.isContentVisible)
        #expect(!controller.isFollowing)
    }

    /// Re-attaching before first layout (`viewport == nil`) still restores the
    /// detached reading place once layout gives the host a size.
    @Test func reattachingBeforeLayoutStillRestoresDetachedPlace() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 300)
        controller.detach(host)

        let again = FakeTranscriptHost()
        again.size = .zero
        again.controller = controller
        controller.attach(again)
        again.resize(to: CGSize(width: 300, height: 200))
        #expect(again.viewportTop == 300)
        #expect(!controller.isFollowing)
    }

    /// Streaming growth during an animated jump keeps stepping smoothly instead
    /// of snapping to the end and jumping back on the next tick.
    @Test func animatedJumpDoesNotSnapDuringGeometryGrowth() {
        let (controller, host) = make()
        host.animatesJumps = true
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 100)
        controller.jumpToEnd(animated: true)
        #expect(controller.endJump != nil)
        let before = host.viewportTop
        controller.setHeights(["row-9": 150])
        // Still near the start of the 0.3s ease-out jump, not snapped to 850.
        #expect(host.viewportTop < before + 200)
    }

    // MARK: Rule 10: selection

    /// Selecting is not a reader move: a reply streaming at the end keeps
    /// following under a selection, as in the Claude and ChatGPT apps.
    @Test func aSelectionKeepsFollowing() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "row-8", offset: 0), focus: TextPosition(rowID: "row-9", offset: 1)))
        controller.setHeights(["row-9": 300])
        #expect(host.viewportTop == 1_000)
        #expect(controller.isFollowing)
    }

    // MARK: Rule 9: preserving scroll position across thread switches

    @Test func savedPlaceIsNilWhileFollowingOrBeforeInitialAlignment() {
        let (controller, host) = make()
        #expect(controller.savedPlace() == nil)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        #expect(controller.isFollowing)
        #expect(controller.savedPlace() == nil)

        host.readerScroll(toTop: 340)
        let saved = controller.savedPlace()
        #expect(saved?.anchorID == "row-3")
        #expect(saved?.offsetIntoRow == 40)
    }

    @Test func restoringSavedPlaceLandsAtRowUnfollowedAndAnchorsOffscreenHeightChanges() throws {
        let (first, firstHost) = make()
        first.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        firstHost.readerScroll(toTop: 340)
        let saved = try #require(first.savedPlace())

        let second = TranscriptController(configuration: .testing)
        let secondHost = FakeTranscriptHost()
        secondHost.size = CGSize(width: 300, height: 200)
        secondHost.controller = second
        second.restoreSavedPlace(saved)
        second.attach(secondHost)
        second.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))

        #expect(secondHost.isContentVisible)
        #expect(secondHost.viewportTop == 340)
        #expect(!second.isFollowing)
        #expect(!second.isEndVisible)

        // Background height measurement above the restored row must keep the
        // reader's visible row pinned in place.
        second.setHeights(["row-0": 220])
        #expect(secondHost.viewportTop == 460)
    }

    @Test func restoringSavedPlaceMatchesBySourceIDBeforeMessageIsParsed() {
        let saved = TranscriptSavedPlace(
            anchorID: "msg-1#2", offsetIntoRow: 30, source: "msg-1", offsetIntoSource: 230,
            expandedTurnIDs: [])
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 300, height: 200)
        host.controller = controller
        controller.restoreSavedPlace(saved)
        controller.attach(host)

        // Initially msg-1 is represented by its pending row sharing sourceID.
        controller.setRows(
            rows(["user-0", "msg-1#pending", "tail"], sources: ["user-0", "msg-1", "tail"]),
            measuredHeights: ["user-0": 200, "msg-1#pending": 500, "tail": 400])
        #expect(host.viewportTop == 430)
        #expect(!controller.isFollowing)
        #expect(!controller.isEndVisible)
    }

    @Test func restoringSavedPlaceFallsBackToEndWhenRowNoLongerExists() {
        let saved = TranscriptSavedPlace(
            anchorID: "deleted-row", offsetIntoRow: 20, source: "deleted-source", offsetIntoSource: 20,
            expandedTurnIDs: [])
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 300, height: 200)
        host.controller = controller
        controller.restoreSavedPlace(saved)
        controller.attach(host)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))

        #expect(host.viewportTop == 800)
        #expect(controller.isFollowing)
        #expect(controller.isEndVisible)
    }

    @Test func jumpToEndBeforeInitialAlignmentOverridesPendingRestorePlace() {
        let saved = TranscriptSavedPlace(
            anchorID: "row-2", offsetIntoRow: 10, source: "row-2", offsetIntoSource: 10,
            expandedTurnIDs: [])
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 300, height: 200)
        host.controller = controller
        controller.restoreSavedPlace(saved)
        controller.attach(host)
        controller.jumpToEnd(animated: false)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))

        #expect(host.viewportTop == 800)
        #expect(controller.isFollowing)
        #expect(controller.isEndVisible)
    }

    @Test func threadStoreSessionPreservesAndClearsSavedPlaceAcrossSwitches() {
        let thread = ChatSyntheticBenchmarkThread.thread(turnCount: 10)
        let store = ThreadStore(previewThreads: [thread.summary], selectedThread: thread)

        // First open: scroll away from the end and detach.
        let first = TranscriptController(configuration: .testing)
        let firstHost = FakeTranscriptHost()
        firstHost.size = CGSize(width: 300, height: 200)
        firstHost.controller = first
        first.attach(firstHost)
        first.start(store: store, threadID: thread.id)
        #expect(!first.rows.isEmpty)
        firstHost.readerScroll(toTop: 250)
        let expectedAnchor = first.savedPlace()
        #expect(expectedAnchor != nil)
        first.detach(firstHost)
        #expect(store.savedTranscriptPlace(for: thread.id) == expectedAnchor)

        // Reopen before initial alignment finishes and detach: must not erase
        // the saved place.
        let aborted = TranscriptController(configuration: .testing)
        let abortedHost = FakeTranscriptHost()
        abortedHost.size = .zero
        abortedHost.controller = aborted
        aborted.attach(abortedHost)
        aborted.start(store: store, threadID: thread.id)
        aborted.detach(abortedHost)
        #expect(store.savedTranscriptPlace(for: thread.id) == expectedAnchor)

        // Reopen with a real viewport: restores the saved scroll position.
        let reopened = TranscriptController(configuration: .testing)
        let reopenedHost = FakeTranscriptHost()
        reopenedHost.size = CGSize(width: 300, height: 200)
        reopenedHost.controller = reopened
        reopened.attach(reopenedHost)
        reopened.start(store: store, threadID: thread.id)
        #expect(!reopened.isFollowing)
        #expect(!reopened.isEndVisible)
        #expect(abs(reopenedHost.viewportTop - 250) < 1)

        // Jumping back to the end and detaching clears the saved place.
        reopened.jumpToEnd(animated: false)
        reopened.detach(reopenedHost)
        #expect(store.savedTranscriptPlace(for: thread.id) == nil)
    }

    @Test func restoringIntoUnderestimatedPendingMessageStaysInsideSourceAndWaitsForParse() {
        // offsetIntoSource (800) exceeds the estimated pending height (200);
        // target must remain strictly inside msg-1#pending, not skip onto tail.
        let saved = TranscriptSavedPlace(
            anchorID: "t|msg-1#2", offsetIntoRow: 50, source: "t|msg-1", offsetIntoSource: 800,
            expandedTurnIDs: [])
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 300, height: 200)
        host.controller = controller
        controller.restoreSavedPlace(saved)
        controller.attach(host)
        controller.setRows(
            [
                TranscriptRow(id: "user-0", sourceID: "user-0", kind: .notice(title: "u", text: nil)),
                TranscriptMessage(kind: .assistant, turnID: "t", ref: "msg-1").pendingRow(source: "hello"),
                TranscriptRow(id: "tail", sourceID: "tail", kind: .notice(title: "t", text: nil)),
            ],
            measuredHeights: ["user-0": 100, "t|msg-1#pending": 200, "tail": 400])

        let target = controller.initialTargetTop(TranscriptViewport(size: host.size, topInset: 0, bottomInset: 0))
        #expect(target.restored)
        #expect(target.top == 299)
        #expect(controller.isAwaitingInitialEnd)
        #expect(!controller.isEndScreenReady(TranscriptViewport(size: host.size, topInset: 0, bottomInset: 0)))
    }

    @Test func restoringPlaceNowNearEndResumesFollowingInsteadOfWedging() throws {
        let (first, firstHost) = make(size: CGSize(width: 300, height: 200))
        first.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        // Scroll slightly above the bottom (endTop = 800, top = 740 -> 60 pt away).
        firstHost.readerScroll(toTop: 740)
        let saved = try #require(first.savedPlace())

        // Reopen in a taller viewport where row-7 + 40 is now at/past endTop (600).
        let second = TranscriptController(configuration: .testing)
        let secondHost = FakeTranscriptHost()
        secondHost.size = CGSize(width: 300, height: 400)
        secondHost.controller = second
        second.restoreSavedPlace(saved)
        second.attach(secondHost)
        second.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))

        #expect(secondHost.viewportTop == 600)
        #expect(second.isEndVisible)
        #expect(second.isFollowing)
        // New content must continue to follow automatically.
        second.setHeights(["row-9": 300])
        #expect(secondHost.viewportTop == 800)
    }

    @Test func animatedJumpDuringInitialAlignmentDoesNotYankViewportAfterReveal() {
        let saved = TranscriptSavedPlace(
            anchorID: "row-1", offsetIntoRow: 20, source: "row-1", offsetIntoSource: 20,
            expandedTurnIDs: [])
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.animatesJumps = true
        host.size = CGSize(width: 300, height: 200)
        host.controller = controller
        controller.restoreSavedPlace(saved)
        controller.attach(host)
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        #expect(controller.isAwaitingInitialEnd)

        controller.jumpToEnd(animated: true)
        #expect(controller.endJump == nil)
        #expect(controller.pendingRestorePlace == nil)
        #expect(host.viewportTop == 800)
    }

    @Test func detachingWithNilViewportPreservesBaselineScrollPosition() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        host.readerScroll(toTop: 340)

        // Simulate AppKit removing the document from its clip view before detach:
        // viewport becomes nil and viewportTop reads 0.
        host.size = .zero
        host.resetOffsetForDetachedClip()
        controller.detach(host)

        let saved = controller.savedPlace()
        #expect(saved?.anchorID == "row-3")
        #expect(saved?.offsetIntoRow == 40)
    }

    @Test func restoringIntoActiveStreamWaitsUntilStreamProducesRows() async throws {
        let turnID = "turn-live"
        let entryRef = "assistant-1"
        let messageID = "\(turnID)|\(entryRef)"
        let liveText = Array(repeating: "Paragraph text with enough content to span multiple blocks.", count: 8)
            .joined(separator: "\n\n")
        let summary = ThreadFixtures.summary(
            id: "live-thread", title: "Live", cwd: "/tmp", agent: ("a", "A"), status: .running,
            createdAt: .now, updatedAt: .now)
        let turn = ThreadFixtures.turn(
            id: turnID, participant: summary.participants[0].id, state: .running, startedAt: .now, settledAt: nil,
            entries: [
                ThreadFixtures.entry(ref: "user-1", kind: .userMessage, text: "Hello"),
                ThreadFixtures.entry(ref: entryRef, kind: .assistantMessage, text: liveText),
            ])
        let detail = ThreadFixtures.detail(summary: summary, turns: [turn])
        let store = ThreadStore(previewThreads: [summary], selectedThread: detail)
        let saved = TranscriptSavedPlace(
            anchorID: "\(messageID)#1", offsetIntoRow: 10, source: messageID, offsetIntoSource: 80,
            expandedTurnIDs: [])
        store.setSavedTranscriptPlace(saved, for: detail.id)

        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 400, height: 200)
        host.controller = controller
        controller.attach(host)
        controller.start(store: store, threadID: detail.id)
        // A loaded test run can take longer than the 1 s readiness timeout,
        // which lands on the end; push it out so only the stream decides.
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(60))

        // Even once every non-streaming row has a layout (frames only tick when
        // the test says so), alignment must still wait for the stream's saved row.
        for row in controller.rows where row.sourceID != messageID {
            controller.storeLayout(RowLayoutBuilder.layout(controller.request(row)))
        }
        controller.alignInitialEndIfPossible()
        #expect(controller.isAwaitingInitialEnd)

        // One frame tick releases the received text at once.
        controller.frameDidTick()
        for _ in 0..<250 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isAwaitingInitialEnd)
        #expect(!controller.isFollowing)
        #expect(controller.rows.contains { $0.id == "\(messageID)#1" })
    }

    @Test func staleNonReplacingSubmitDoesNotOverwriteNewerGeneration() async throws {
        let delivered = Mutex<[RowLayoutKey]>([])
        let queue = LayoutQueue(concurrency: 1) { result in
            if case .layout(let layout, _) = result {
                delivered.withLock { $0.append(layout.key) }
            }
        }
        let style = TextStyle.current()
        let oldKey = RowLayoutKey(contentVersion: 0, width: 300, styleVersion: style.version)
        let newKey = RowLayoutKey(contentVersion: 0, width: 500, styleVersion: style.version)
        let helloBlocks: [MarkdownBlock] = [.paragraph([MarkdownInline(text: "Hello")])]
        let oldJob = LayoutQueue.Job(
            id: "layout|row-0",
            work: .layout(RowLayoutRequest(rowID: "row-0", kind: .userMessage(helloBlocks), key: oldKey, style: style)),
            priority: 0)
        let newJob = LayoutQueue.Job(
            id: "layout|row-0",
            work: .layout(RowLayoutRequest(rowID: "row-0", kind: .userMessage(helloBlocks), key: newKey, style: style)),
            priority: 0)

        await queue.submit(urgent: [newJob], generation: 2, replacingUrgent: true)
        await queue.submit(urgent: [oldJob], generation: 1, replacingUrgent: false)

        for _ in 0..<50 where delivered.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let keys = delivered.withLock { $0 }
        #expect(keys == [newKey])
    }

    @Test func unscheduledPendingMessageEnteringViewportParsesAsynchronouslyWithoutSyncLayout() async throws {
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 400, height: 200)
        host.controller = controller
        controller.attach(host)

        let source = "First paragraph.\n\nSecond paragraph."
        let hiBlocks: [MarkdownBlock] = [.paragraph([MarkdownInline(text: "Hi")])]
        let tailBlocks: [MarkdownBlock] = [.paragraph([MarkdownInline(text: "Tail")])]
        let tallUser = TranscriptRow(id: "u0", sourceID: "u0", kind: .userMessage(hiBlocks), messageID: "u0", role: .user)
        let pendingMessage = TranscriptMessage(kind: .assistant, turnID: "t", ref: "m1")
        let pendingRow = pendingMessage.pendingRow(source: source)
        let tailRows = (0..<30).map {
            TranscriptRow(id: "t\($0)", sourceID: "t\($0)", kind: .userMessage(tailBlocks), messageID: "t\($0)", role: .user)
        }
        // Put pending row at y=3000, outside both the initial end window and the
        // top window (-400..400), so scheduleWork() never queues it.
        var initialHeights: [String: CGFloat] = ["u0": 3000, pendingRow.id: 60]
        for row in tailRows { initialHeights[row.id] = 44 }
        controller.setRows([tallUser, pendingRow] + tailRows, measuredHeights: initialHeights)
        for _ in 0..<50 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(10))
        }
        host.readerScroll(toTop: 0)
        controller.setHeights(["u0": 40])
        #expect(controller.rows.contains { $0.id == pendingRow.id })

        // Now pending row sits in the visible viewport without any reader scroll.
        // Mounting sees no cached layout and prefetches the parse off-main.
        let mounter = TranscriptRowMounter(container: CALayer())
        mounter.place(
            controller, visible: CGRect(x: 0, y: 0, width: 400, height: 200), documentWidth: 400,
            palette: TextPalette.resolveForTests, scale: 2, showsContent: true)

        for _ in 0..<50 where controller.rows.contains(where: { $0.id == pendingRow.id }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.rows.contains { $0.id == pendingRow.id })
        #expect(controller.rows.contains { $0.id == "\(pendingMessage.id)#0" })
        #expect(controller.rows.contains { $0.id == "\(pendingMessage.id)#1" })
    }

    @Test func removingAndReaddingRowWithSameIDDropsStaleCachedLayout() {
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 400, height: 300)
        host.controller = controller
        controller.attach(host)

        let user = TranscriptRow(
            id: "u0", sourceID: "u0", kind: .userMessage([.paragraph([MarkdownInline(text: "Hi")])]),
            messageID: "u0", role: .user)
        let working1 = TranscriptRow(id: "working", kind: .working(phrase: "Pondering…"))
        controller.setRows([user, working1])
        let firstLayout = RowLayoutBuilder.layout(controller.request(controller.rows[1]))
        controller.storeLayout(firstLayout)
        #expect(controller.layouts["working"] != nil)

        // Turn ends: `"working"` is removed. Its cached layout must be dropped.
        controller.replaceRows(1..<2, with: [], heights: [:])
        #expect(controller.layouts["working"] == nil)

        // Next turn starts with a new phrase under the same `"working"` ID.
        let working2 = TranscriptRow(id: "working", kind: .working(phrase: "Tinkering with a much longer phrase…"))
        controller.replaceRows(1..<1, with: [working2], heights: [:])
        #expect(controller.layouts["working"] == nil)
        let secondLayout = RowLayoutBuilder.layout(controller.request(controller.rows[1]))
        controller.storeLayout(secondLayout)
        if case .text(let textLayout, _) = controller.layout(forRowAt: 1)?.content {
            #expect(textLayout.string.contains("Tinkering"))
        } else {
            Issue.record("expected text layout for working row")
        }
    }

    #if os(iOS)
        private final class StubTouch: UITouch {
            private let targetView: UIView
            init(view: UIView) {
                targetView = view
                super.init()
            }
            override var view: UIView? { targetView }
        }

        @Test func verticalDragStartingOnAccessoryButtonScrollsTranscript() {
            let controller = TranscriptController(configuration: .launch)
            let scrollView = TranscriptScrollView(controller: controller)
            let button = TranscriptAccessoryControl()
            let touch = StubTouch(view: button)

            let tap = scrollView.gestureRecognizers?
                .compactMap { $0 as? UITapGestureRecognizer }
                .first { $0.delegate === scrollView.tapDelegate }
            #expect(tap != nil)
            if let tap {
                #expect(!scrollView.tapDelegate.gestureRecognizer(tap, shouldReceive: touch))
            }
            let panAcceptsButtonTouch =
                scrollView.panGestureRecognizer.delegate?.gestureRecognizer?(
                    scrollView.panGestureRecognizer, shouldReceive: touch) ?? true
            #expect(panAcceptsButtonTouch)
            #expect(scrollView.touchesShouldCancel(in: button))
        }

        /// `editMenu` places Comment… inline right after `.standardEdit`, and
        /// `willMove(toWindow: nil)` clears selection to avoid UIKit preview
        /// target crashes on detached views.
        @Test func iosEditMenuPromotesCommentAndWindowDetachClearsSelection() throws {
            let controller = TranscriptController(configuration: .testing)
            let scrollView = TranscriptScrollView(controller: controller)
            let row = TranscriptRow(
                id: "r0", sourceID: "m",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "Hello world")]), .single),
                messageID: "m", role: .assistant)
            controller.setRows([row], measuredHeights: ["r0": 40])
            controller.setSelection(
                TranscriptSelection(
                    anchor: TextPosition(rowID: "r0", offset: 0),
                    focus: TextPosition(rowID: "r0", offset: 5)))
            scrollView.onComment = { _, _, _ in }

            let standardEdit = UIMenu(identifier: .standardEdit, children: [])
            let lookup = UIMenu(identifier: .lookup, children: [])
            let textRange = try #require(scrollView.contentView.selectedTextRange)
            let menu = try #require(
                scrollView.contentView.editMenu(for: textRange, suggestedActions: [standardEdit, lookup]))
            #expect(menu.children.count == 3)
            #expect((menu.children[0] as? UIMenu)?.identifier == .standardEdit)
            #expect((menu.children[1] as? UIAction)?.title == "Comment…")
            #expect((menu.children[2] as? UIMenu)?.identifier == .lookup)

            scrollView.contentView.willMove(toWindow: nil)
            #expect(controller.selection == nil)

            // Tokenizer boundary clamping respects direction and never loops at row edges.
            let r1 = TranscriptRow(
                id: "r1", sourceID: "m2",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "Second row")]), .single))
            controller.setRows([row, r1], measuredHeights: ["r0": 40, "r1": 40])
            let startOfR0 = TranscriptTextPosition(TextPosition(rowID: "r0", offset: 0))
            let endOfR0 = TranscriptTextPosition(TextPosition(rowID: "r0", offset: 11))
            #expect(scrollView.contentView.isPosition(startOfR0, atBoundary: .word, inDirection: .storage(.backward)))
            #expect(!scrollView.contentView.isPosition(startOfR0, atBoundary: .word, inDirection: .storage(.forward)))
            #expect(scrollView.contentView.position(from: startOfR0, toBoundary: .word, inDirection: .storage(.backward)) == nil)
            #expect(scrollView.contentView.position(from: endOfR0, toBoundary: .word, inDirection: .storage(.forward)) == nil)
        }
    #endif

    /// Remembered measured heights keyed by `(columnWidth, styleVersion)` seed
    /// both `.pendingMessage` (via summed `sourceHeights`) and parsed block
    /// rows when reopening a thread at the same width, and are ignored if the
    /// width or style changed.
    @Test func rememberedHeightsEliminateRevisitDriftAtMatchingWidth() throws {
        let first = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 600, height: 400)
        host.controller = first
        first.attach(host)
        let msg = TranscriptMessage(kind: .assistant, turnID: "t1", ref: "a1")
        let blocks: [MarkdownBlock] = [
            .paragraph([MarkdownInline(text: "Block one")]),
            .paragraph([MarkdownInline(text: "Block two")]),
        ]
        let parsedRows = msg.rows(from: blocks)
        first.setRows(parsedRows, measuredHeights: [parsedRows[0].id: 123, parsedRows[1].id: 234])
        first.measuredRowHeights[parsedRows[0].id] = 123
        first.measuredRowHeights[parsedRows[1].id] = 234
        let snapshot = try #require(first.snapshotMeasuredHeights())
        #expect(snapshot.width == first.columnWidth)
        #expect(snapshot.rowHeights[parsedRows[0].id] == 123)
        #expect(snapshot.rowHeights[parsedRows[1].id] == 234)
        #expect(snapshot.sourceHeights[msg.id] == 357)

        // Reopen at matching width: pending message immediately gets 357 pt
        // instead of a rough estimate, and parsed blocks keep 123 + 234 pt.
        let second = TranscriptController(configuration: .testing)
        second.rememberedHeights = snapshot
        let secondHost = FakeTranscriptHost()
        secondHost.size = CGSize(width: 600, height: 400)
        secondHost.controller = second
        second.attach(secondHost)
        second.setRows([msg.pendingRow(source: "Block one\n\nBlock two")])
        #expect(second.geometry.totalHeight == 357)

        second.replaceRows(0..<1, with: parsedRows, heights: [:])
        #expect(second.geometry.height(at: 0) == 123)
        #expect(second.geometry.height(at: 1) == 234)

        // Reopen at a different width: remembered heights are ignored.
        let third = TranscriptController(configuration: .testing)
        third.rememberedHeights = snapshot
        let thirdHost = FakeTranscriptHost()
        thirdHost.size = CGSize(width: 400, height: 400)
        thirdHost.controller = third
        third.attach(thirdHost)
        third.setRows([msg.pendingRow(source: "Block one\n\nBlock two")])
        #expect(third.geometry.totalHeight != 357)

        // Changing a row's kind in `replaceRows` must discard its stale
        // `measuredRowHeights` entry and re-estimate rather than reusing 123 pt.
        let replacedRow = TranscriptRow(
            id: parsedRows[0].id, sourceID: msg.id,
            kind: .markdownBlock(
                .paragraph([MarkdownInline(text: String(repeating: "Expanded content ", count: 80))]), .single))
        first.replaceRows(0..<1, with: [replacedRow], heights: [:])
        #expect(first.measuredRowHeights[parsedRows[0].id] == nil)
        #expect(first.geometry.height(at: 0) != 123)
    }
}
