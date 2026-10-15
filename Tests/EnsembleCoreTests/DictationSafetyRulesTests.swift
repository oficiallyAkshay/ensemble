import Foundation
import Testing
@testable import EnsembleCore

@Suite struct DictationSafetyRulesTests {
    // MARK: An unreadable microphone with a record open

    @Test func unreadableForLongEnoughWithARecordSoundsTheAlarm() {
        #expect(DictationRules.escalateUnreadable(recordOpen: true, holdActive: false, unreadableFor: DictationRules.unreadableLimit))
        #expect(DictationRules.escalateUnreadable(recordOpen: true, holdActive: false, unreadableFor: 30))
    }

    @Test func unreadableIsToleratedBrieflyOrWithoutARecord() {
        #expect(!DictationRules.escalateUnreadable(recordOpen: true, holdActive: false, unreadableFor: 2.9))
        #expect(!DictationRules.escalateUnreadable(recordOpen: false, holdActive: false, unreadableFor: 30))
        // While the hold runs, the dead-man check owns the dictation.
        #expect(!DictationRules.escalateUnreadable(recordOpen: true, holdActive: true, unreadableFor: 30))
    }

    // MARK: Deleting the record while a start press is in flight

    @Test func aStartPressInFlightKeepsTheRecordPastTheSettleWindow() {
        #expect(!DictationRules.recordMayGo(capture: false, startInFlight: true, offFor: 30, settle: 3))
        // The launch sweep needs no settle window, and still waits for the press.
        #expect(!DictationRules.recordMayGo(capture: false, startInFlight: true, offFor: 0, settle: 0))
    }

    @Test func theRecordGoesOnceThePressHasLandedAndOffHasSettled() {
        #expect(DictationRules.recordMayGo(capture: false, startInFlight: false, offFor: 3, settle: 3))
        #expect(DictationRules.recordMayGo(capture: false, startInFlight: false, offFor: 0, settle: 0))
        #expect(!DictationRules.recordMayGo(capture: false, startInFlight: false, offFor: 2.9, settle: 3))
        #expect(!DictationRules.recordMayGo(capture: true, startInFlight: false, offFor: 30, settle: 3))
        #expect(!DictationRules.recordMayGo(capture: nil, startInFlight: false, offFor: 30, settle: 3))
    }

    // MARK: A new dictation during an unconfirmed stop

    @Test func aStartIsRefusedWhileAStopIsOwed() {
        #expect(DictationRules.startRefusal(stopOwed: true, alarmOn: false, muteInEffect: false) != nil)
        #expect(DictationRules.startRefusal(stopOwed: false, alarmOn: true, muteInEffect: false) != nil)
        #expect(DictationRules.startRefusal(stopOwed: false, alarmOn: false, muteInEffect: true) != nil)
    }

    @Test func aStartIsAllowedWhenNothingIsOwed() {
        #expect(DictationRules.startRefusal(stopOwed: false, alarmOn: false, muteInEffect: false) == nil)
    }

    // MARK: Interrupted dictations are never sendable

    @Test func onlyAnOrdinaryUninterruptedStopIsSendable() {
        #expect(DictationRules.sendableAfterStop(immediate: false, interrupted: false))
        #expect(!DictationRules.sendableAfterStop(immediate: true, interrupted: false))
        #expect(!DictationRules.sendableAfterStop(immediate: false, interrupted: true))
        #expect(!DictationRules.sendableAfterStop(immediate: true, interrupted: true))
    }

    // MARK: Waiting for the transcript to settle

    @Test func aFinalDraftIsReadyAfterTheQuietTime() {
        var s = DraftSettle(start: 10, first: "hello there")
        let early = s.observe("hello there", at: 10.1)
        let almost = s.observe("hello there", at: 10 + DraftSettle.quiet - 0.01)
        let ready = s.observe("hello there", at: 10 + DraftSettle.quiet)
        #expect(!early)
        #expect(!almost)
        #expect(ready)
        #expect(s.text == "hello there")
    }

    @Test func aChangeRestartsTheQuietTime() {
        var s = DraftSettle(start: 0, first: "hello")
        let a = s.observe("hello", at: 0.2)
        let b = s.observe("hello there", at: 0.25)
        let c = s.observe("hello there", at: 0.5)
        let d = s.observe("hello there", at: 0.55)
        #expect(!a)
        #expect(!b)
        #expect(!c)
        #expect(d)
        #expect(s.text == "hello there")
        #expect(abs(s.lastChangeAfter - 0.25) < 1e-9)
    }

    @Test func anEmptyDraftWaitsUntilTheCap() {
        var s = DraftSettle(start: 0, first: "")
        let a = s.observe("  ", at: 0.5)
        let b = s.observe("  ", at: 1.0)
        let c = s.observe("  ", at: DraftSettle.cap)
        #expect(!a)
        #expect(!b)
        #expect(c)
    }

    @Test func aDraftThatKeepsChangingStopsAtTheCap() {
        var s = DraftSettle(start: 0, first: "a")
        var t = 0.0
        var n = 1
        var ready = false
        while !ready {
            t += 0.1
            n += 1
            ready = s.observe(String(repeating: "a", count: n), at: t)
        }
        #expect(t >= DraftSettle.cap - 1e-9 && t < DraftSettle.cap + 0.1)
    }

    @Test func theQuietTimeIsShorterThanTheOldFixedWait() {
        #expect(DraftSettle.quiet < 0.6)
        #expect(DraftSettle.cap > DraftSettle.quiet)
    }
}
