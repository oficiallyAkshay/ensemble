import Testing
@testable import EnsembleCore

@Suite struct TourStateMachineTests {
    @Test func stepsStartAtWelcome() {
        let m = TourStateMachine()
        #expect(m.step == .welcome)
        #expect(!m.canGoBack)
        #expect(m.canGoNext)
    }

    @Test func nextWalksForwardAndStopsAtDone() {
        let m = TourStateMachine()
        for expected: TourStep in [.calibrate, .gestures, .noseDot, .permissions, .done] {
            #expect(m.next())
            #expect(m.step == expected)
        }
        #expect(!m.next())
        #expect(m.step == .done)
        #expect(m.finished)
    }

    @Test func backWalksBackwardAndStopsAtWelcome() {
        let m = TourStateMachine(startAt: .permissions)
        #expect(m.back())
        #expect(m.step == .noseDot)
        #expect(m.back())
        #expect(m.step == .gestures)
        #expect(m.back())
        #expect(m.step == .calibrate)
        #expect(m.back())
        #expect(m.step == .welcome)
        #expect(!m.back())
        #expect(m.step == .welcome)
    }

    @Test func jumpSetsStepDirectlyAndFinishesOnDone() {
        let m = TourStateMachine()
        m.jump(to: .permissions)
        #expect(m.step == .permissions)
        #expect(!m.finished)
        m.jump(to: .done)
        #expect(m.finished)
    }

    @Test func skipMarksSkippedAndFinished() {
        let m = TourStateMachine(startAt: .gestures)
        m.skip()
        #expect(m.skipped)
        #expect(m.finished)
    }

    @Test func noseDotStepSitsAfterGesturesAndTheTourHasSixSteps() {
        #expect(TourStep.allCases.count == 6)
        #expect(TourStep.noseDot.rawValue == TourStep.gestures.rawValue + 1)
        #expect(TourStep.noseDot.title == "Nose dot")
    }

    @Test func singleStepDisablesBackAndNext() {
        let m = TourStateMachine(startAt: .gestures, singleStep: true)
        #expect(!m.canGoBack)
        #expect(!m.canGoNext)
        #expect(!m.next())
        #expect(!m.back())
        #expect(m.step == .gestures)
    }

    @Test func practiceDoneAccumulatesAndCompletesOnce() {
        let m = TourStateMachine(startAt: .gestures)
        #expect(!m.allPracticeDone)
        m.markPracticeDone(.dictate)
        m.markPracticeDone(.send)
        #expect(!m.allPracticeDone)
        m.markPracticeDone(.scroll)
        #expect(m.allPracticeDone)
        m.markPracticeDone(.scroll)   // re-observing the same gesture does not break anything
        #expect(m.allPracticeDone)
    }
}
