import Testing
@testable import EnsembleCore

@Suite struct DictationRulesTests {
    // MARK: Switching off while a start press is in flight

    @Test func aStartThatLandsAfterSwitchOffIsStoppedAtOnce() {
        // The pose may still read as held (the gesture machine was reset, or a headphone start): switching off wins.
        #expect(DictationRules.afterStart(confirmedOn: true, switchedOff: true, poseHeld: true) == .stopSwitchedOff)
        #expect(DictationRules.afterStart(confirmedOn: true, switchedOff: true, poseHeld: false) == .stopSwitchedOff)
    }

    @Test func aStartThatLandsNormallyFollowsThePose() {
        #expect(DictationRules.afterStart(confirmedOn: true, switchedOff: false, poseHeld: true) == .keepListening)
        #expect(DictationRules.afterStart(confirmedOn: true, switchedOff: false, poseHeld: false) == .stopReleased)
    }

    @Test func anUnconfirmedStartIsNotListening() {
        for off in [true, false] {
            for held in [true, false] {
                #expect(DictationRules.afterStart(confirmedOn: false, switchedOff: off, poseHeld: held) == .notStarted)
            }
        }
    }

    @Test func theSafetyStopLineCarriesTheReasonAndEveryNumber() {
        let line = DictationRules.safetyStopLine(reason: "Claude is capturing audio with no hold active", sinceHoldEnded: 12.4,
                                                 sinceReadOff: 3.6, startInFlight: true, recordAge: 40)
        #expect(line == "safety stop begun (Claude is capturing audio with no hold active): hold ended 12 s ago, "
                + "microphone last read off 4 s ago, start press in flight yes, record age 40 s")
    }

    @Test func theSafetyStopLineSaysNeverWhenNothingHappened() {
        let line = DictationRules.safetyStopLine(reason: "recording found at launch from a previous run", sinceHoldEnded: nil,
                                                 sinceReadOff: nil, startInFlight: false, recordAge: 0)
        #expect(line.contains("hold ended never"))
        #expect(line.contains("microphone last read off never"))
        #expect(line.contains("start press in flight no"))
    }

    @Test func disarmWaitsForAPressInFlight() {
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: true, waited: 0) == .wait)
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: true, waited: 3.5) == .wait)   // the old 3 s wait
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: false, waited: 7.9) == .wait)
    }

    @Test func disarmNeverClearsWhileAStartIsStillInFlight() {
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: true, waited: DictationRules.disarmWait) == .stopWhenStarted)
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: true, waited: 60) == .stopWhenStarted)
    }

    @Test func disarmProceedsWhenNothingCanOpenTheMicrophone() {
        #expect(DictationRules.disarmStep(stepInFlight: false, startInFlight: false, waited: 0) == .proceed)
        // A stop or send that outlives the wait cannot open the microphone; the stop-and-confirm runs next.
        #expect(DictationRules.disarmStep(stepInFlight: true, startInFlight: false, waited: DictationRules.disarmWait) == .proceed)
    }

    // MARK: Unreadable microphone state

    @Test func onlyADefiniteOffReadingConfirmsOff() {
        #expect(DictationRules.confirmedOff(capture: false))
        #expect(!DictationRules.confirmedOff(capture: true))
        #expect(!DictationRules.confirmedOff(capture: nil))      // CoreAudio restarting: Claude may be recording
    }

    @Test func findingNoPaneIsNotAConfirmedStop() {
        #expect(DictationRules.stopAll(paneConfirmedOff: []) == .nothingFound)
    }

    @Test func everyPaneMustConfirmOff() {
        #expect(DictationRules.stopAll(paneConfirmedOff: [true]) == .allOff)
        #expect(DictationRules.stopAll(paneConfirmedOff: [true, true]) == .allOff)
        #expect(DictationRules.stopAll(paneConfirmedOff: [true, false]) == .notAllOff)
        #expect(DictationRules.stopAll(paneConfirmedOff: [false]) == .notAllOff)
    }
}
