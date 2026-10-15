import Testing
@testable import EnsembleCore

@Suite struct TourPracticeDetectorTests {
    @Test func dictateNeedsAFullStartAndStopPair() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
    }

    @Test func talkEndedAloneDoesNotCompleteDictate() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkEnded(.stale)) == nil)
    }

    @Test func resetDiscardsAPendingTalkBegan() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        d.reset()
        #expect(d.observe(.talkEnded(.released)) == nil)
    }

    @Test func sendAndScrollCompleteOnTheirOwnIntent() {
        let d = TourPracticeDetector()
        #expect(d.observe(.sendRequested) == .send)
        #expect(d.observe(.dragScroll(handDy: 12)) == .scroll)
    }

    @Test func unrelatedIntentsCompleteNothing() {
        let d = TourPracticeDetector()
        #expect(d.observe(.scroll(dy: 5)) == nil)
        #expect(d.observe(.dragScrollEnded) == nil)
    }

    @Test func dictateCanBePracticedAgainAfterCompleting() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
    }
}
