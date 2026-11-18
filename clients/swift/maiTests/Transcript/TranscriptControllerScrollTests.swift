import CoreGraphics
import Foundation
import Testing

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

    // MARK: Rule 10: selection

    @Test func startingASelectionStopsFollowing() {
        let (controller, host) = make()
        controller.setRows(rows(tenRows), measuredHeights: uniform(tenRows, 100))
        controller.noteSelectionStarted()
        controller.setHeights(["row-9": 300])
        #expect(host.viewportTop == 800)
        #expect(!controller.isFollowing)
    }
}
