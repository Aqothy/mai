#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import Testing

    @testable import mai

    /// Scrolling with the pointer over a wide code block or table (PLAN
    /// 3.9): a gesture goes to the axis it started on, so a vertical swipe
    /// scrolls only the transcript however it drifts sideways.
    @MainActor
    struct TranscriptMacScrollRoutingTests {
        private final class RecordingScrollView: NSScrollView {
            var received = 0
            override func scrollWheel(with event: NSEvent) { received += 1 }
        }

        private func event(dx: Int32, dy: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase = .none)
            -> NSEvent
        {
            let cg = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
            if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return NSEvent(cgEvent: cg)!
        }

        private func make() -> (TranscriptWideBlockScrollView, RecordingScrollView) {
            let transcript = RecordingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            let block = TranscriptWideBlockScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            block.transcriptScrollView = transcript
            return (block, transcript)
        }

        @Test func aVerticalSwipeThatDriftsSidewaysScrollsOnlyTheTranscript() {
            let (block, transcript) = make()
            block.scrollWheel(with: event(dx: 0, dy: -12, phase: .began))
            block.scrollWheel(with: event(dx: 9, dy: -2, phase: .changed))
            block.scrollWheel(with: event(dx: 0, dy: 0, phase: .ended))
            block.scrollWheel(with: event(dx: 6, dy: -1, phase: nil, momentum: .begin))
            #expect(transcript.received == 4)
        }

        @Test func aSidewaysSwipeStaysWithTheBlockEvenIfItTurnsVertical() {
            let (block, transcript) = make()
            block.scrollWheel(with: event(dx: -12, dy: 1, phase: .began))
            block.scrollWheel(with: event(dx: -1, dy: -20, phase: .changed))
            block.scrollWheel(with: event(dx: 0, dy: -8, phase: nil, momentum: .continuous))
            #expect(transcript.received == 0)
            // The next gesture decides again.
            block.scrollWheel(with: event(dx: 0, dy: -5, phase: .began))
            #expect(transcript.received == 1)
        }

        @Test func aMouseWheelGoesToTheTranscript() {
            let (block, transcript) = make()
            block.scrollWheel(with: event(dx: 0, dy: -3, phase: nil))
            #expect(transcript.received == 1)
        }
    }
#endif
