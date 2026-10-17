import Foundation
import Testing
@testable import EnsembleCore

@Suite struct DictationSafetyRulesTests {
    // MARK: The dead-man check

    @Test func theHoldEndsAfterOneSecondWithoutAHeartbeat() {
        #expect(DictationRules.heartbeatTimeout == 1)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 0.99, longestStall: 0) == nil)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 1, longestStall: 0) == nil)       // greater-than, not at
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 1.01, longestStall: 0) == .noHeartbeat)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 1.01, longestStall: 30) == .noHeartbeat)
    }

    @Test func theHoldEndsAfterAnAccessibilityStallOfThreeSeconds() {
        #expect(DictationRules.stallLimit == 3)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 0, longestStall: 2.99) == nil)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 0, longestStall: 3) == nil)
        #expect(DictationRules.holdLoss(holdActive: true, heartbeatAge: 0, longestStall: 3.01) == .stalled)
    }

    @Test func noHoldMeansNothingToEnd() {
        #expect(DictationRules.holdLoss(holdActive: false, heartbeatAge: 30, longestStall: 30) == nil)
    }

    // MARK: The fallback alarm for an unconfirmed stop

    @Test func aStopUnconfirmedForThreeSecondsSoundsTheAlarm() {
        #expect(DictationRules.escalateAfter == 3)
        #expect(!DictationRules.escalateStop(alarmOn: false, owedFor: 2.99))
        #expect(DictationRules.escalateStop(alarmOn: false, owedFor: 3))
        #expect(DictationRules.escalateStop(alarmOn: false, owedFor: 30))
    }

    @Test func theAlarmIsRaisedOnce() {
        #expect(!DictationRules.escalateStop(alarmOn: true, owedFor: 30))
    }

    // MARK: The standing check

    @Test func theRecordGoesAfterThreeSecondsConfirmedOff() {
        #expect(DictationRules.settleWindow == 3)
        let settle = DictationRules.settleWindow
        #expect(!DictationRules.recordMayGo(capture: false, startInFlight: false, offFor: 2.99, settle: settle))
        #expect(DictationRules.recordMayGo(capture: false, startInFlight: false, offFor: 3, settle: settle))
    }

    @Test func theStandingCheckWaitsOneSecondAfterAHoldEnds() {
        #expect(DictationRules.standingCheckGrace == 1)
        #expect(!DictationRules.standingCheckActs(recordOpen: true, holdActive: false, sinceHoldEnded: 1))
        #expect(DictationRules.standingCheckActs(recordOpen: true, holdActive: false, sinceHoldEnded: 1.01))
    }

    @Test func theStandingCheckLeavesAHoldAndANoRecordAlone() {
        #expect(!DictationRules.standingCheckActs(recordOpen: true, holdActive: true, sinceHoldEnded: 30))
        #expect(!DictationRules.standingCheckActs(recordOpen: false, holdActive: false, sinceHoldEnded: 30))
    }

    // MARK: Written before pressed

    @Test func aPressIsPermittedOnlyOnceTheRecordIsWritten() {
        var writes = 0
        #expect(DictationRules.pressRefusal(nil) { writes += 1; return true } == nil)
        #expect(DictationRules.pressRefusal(nil) { writes += 1; return false } != nil)
        #expect(writes == 2)
    }

    @Test func aRefusedStartWritesNoRecordAndPressesNothing() {
        var writes = 0
        #expect(DictationRules.pressRefusal("refused") { writes += 1; return true } == "refused")
        #expect(writes == 0)
    }

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

    @Test func theStandingCheckRestartsTheOffCountWhileAStartPressIsInFlight() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let settle = DictationRules.settleWindow
        var offSince: Date?
        var mayGo = false
        // Off for 30 s, all of it with the press in flight: the record stays and the off count never starts.
        for second in 0...30 {
            (offSince, mayGo) = DictationRules.offReading(offSince: offSince, now: t0 + Double(second), startInFlight: true, settle: settle)
            #expect(offSince == nil)
            #expect(!mayGo)
        }
        // The first off reading after the press lands starts the count; the record goes only after the settle window.
        let landed = t0 + 31
        (offSince, mayGo) = DictationRules.offReading(offSince: offSince, now: landed, startInFlight: false, settle: settle)
        #expect(offSince == landed)
        #expect(!mayGo)
        (offSince, mayGo) = DictationRules.offReading(offSince: offSince, now: landed + settle - 0.01, startInFlight: false, settle: settle)
        #expect(!mayGo)
        (offSince, mayGo) = DictationRules.offReading(offSince: offSince, now: landed + settle, startInFlight: false, settle: settle)
        #expect(offSince == landed)
        #expect(mayGo)
    }

    @Test func aPressInFlightMidwayRestartsTheSettleWindow() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let settle = DictationRules.settleWindow
        let (since, _) = DictationRules.offReading(offSince: nil, now: t0, startInFlight: false, settle: settle)
        let (during, keep) = DictationRules.offReading(offSince: since, now: t0 + 2, startInFlight: true, settle: settle)
        #expect(during == nil)
        #expect(!keep)
        let (after, mayGo) = DictationRules.offReading(offSince: during, now: t0 + 4, startInFlight: false, settle: settle)
        #expect(after == t0 + 4)
        #expect(!mayGo)
    }

    @Test func theLaunchSweepClearsAtOnceOnlyWithNoPressInFlight() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!DictationRules.offReading(offSince: nil, now: now, startInFlight: true, settle: 0).recordMayGo)
        #expect(DictationRules.offReading(offSince: nil, now: now, startInFlight: false, settle: 0).recordMayGo)
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
