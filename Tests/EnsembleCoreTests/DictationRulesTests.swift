import Testing
@testable import EnsembleCore

@Suite struct DictationRulesTests {
    // MARK: Deleting the safety record

    @Test func aStartPressInFlightKeepsTheRecordPastTheSettleWindow() {
        // The start press came back late: the microphone reads off now but could still open once the press lands.
        #expect(!DictationRules.mayFinishEpisode(capture: false, startInFlight: true, offFor: 10))
        #expect(DictationRules.mayFinishEpisode(capture: false, startInFlight: false, offFor: DictationRules.settleWindow))
    }

    @Test func onlyASettledDefiniteOffDeletesTheRecord() {
        #expect(!DictationRules.mayFinishEpisode(capture: false, startInFlight: false, offFor: 2.9))
        #expect(!DictationRules.mayFinishEpisode(capture: true, startInFlight: false, offFor: 10))
        #expect(!DictationRules.mayFinishEpisode(capture: nil, startInFlight: false, offFor: 10))
    }

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
