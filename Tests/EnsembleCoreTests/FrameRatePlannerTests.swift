import Foundation
import Testing
@testable import EnsembleCore

struct FrameRatePlannerTests {
    /// Runs a 30 fps camera for `seconds` and counts what ran. `face` says whether a face is seen on every frame.
    private func simulate(_ p: inout FrameRatePlanner, from t0: TimeInterval = 0, seconds: Double, face: Bool, force: Bool = false,
                          slowFace: Bool = false, otherApp: Bool = false,
                          hand: (TimeInterval) -> Bool = { _ in false }) -> (hand: Int, face: Int, light: Int) {
        var counts = (hand: 0, face: 0, light: 0)
        var lastFace: TimeInterval? = face ? t0 : nil
        let frames = Int(seconds * 30)
        for i in 0..<frames {
            let t = t0 + Double(i) / 30
            if face { lastFace = t }
            let plan = p.plan(now: t, forceFull: force, lastFaceSeenAt: lastFace, slowFace: slowFace, otherAppInFront: otherApp)
            if plan.runHand { counts.hand += 1; p.noteHand(present: hand(t), at: t) }
            if plan.runFace { counts.face += 1 }
            if plan.runLight { counts.light += 1 }
        }
        return counts
    }

    /// The tour's gesture practice forces full rate, so the skeleton inset gets a reading on every camera frame even
    /// when no hand is in view yet and no face has been seen for longer than the idle slowdown.
    @Test func forcedFullRateRunsHandPoseOnEveryFrameWithNoHandAndNoFace() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 10, face: false, force: true)
        #expect(c.hand == 300)
    }

    @Test func facePresentNoHandProbesHandAtAboutEightHz() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 10, face: true)
        #expect((70...95).contains(c.hand))        // ~8 Hz, quantized to camera frames
        #expect((295...300).contains(c.face))      // 30 Hz: every frame
        #expect((95...105).contains(c.light))      // ~10 Hz
    }

    @Test func handInViewRunsEveryFrameAndHoldsAfterItLeaves() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 2, face: true)
        // Hand appears at t = 2 s and stays 2 s: found by the next probe, then every frame.
        let during = simulate(&p, from: 2, seconds: 2, face: true, hand: { _ in true })
        #expect(during.hand >= 2 * 30 - 4)
        // Hand gone at t = 4 s: still full rate for the 1 s hold, then back to the probe.
        let after = simulate(&p, from: 4, seconds: 1, face: true)
        #expect(after.hand >= 28)
        let later = simulate(&p, from: 5, seconds: 5, face: true)
        #expect(later.hand <= 5 * 8 + 5)
    }

    @Test func forcedFullKeepsEveryHandFrameWithoutAHand() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 5, face: true, force: true)
        #expect(c.hand == 150)
    }

    @Test func noFaceForSecondsDropsBothToAboutTwoHz() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 1, face: true)
        _ = simulate(&p, from: 1, seconds: 3, face: false)           // the 3 s grace
        let idle = simulate(&p, from: 4, seconds: 10, face: false)
        #expect((18...25).contains(idle.hand))
        #expect((18...25).contains(idle.face))
    }

    @Test func forcedFullCancelsTheIdleSlowdown() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 8, face: false)
        let c = simulate(&p, from: 8, seconds: 3, face: false, force: true)
        #expect(c.hand == 90)
        #expect((88...90).contains(c.face))
    }

    @Test func aFaceReturningRestoresFullRateWithinOneFrame() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 10, face: false)
        let plan = p.plan(now: 10.2, forceFull: false, lastFaceSeenAt: 10.2)
        #expect(plan.runFace)
        #expect(plan.runHand)
        let next = p.plan(now: 10.2 + 1.0 / 30, forceFull: false, lastFaceSeenAt: 10.2)
        #expect(next.runFace)                      // full rate: every frame
    }

    @Test func theVeryFirstFrameRunsEverything() {
        var p = FrameRatePlanner()
        #expect(p.plan(now: 100, forceFull: false, lastFaceSeenAt: nil) == .init(runHand: true, runFace: true, runLight: true))
    }

    @Test func slowFaceRunsTheFaceAtTenHzAndLeavesTheHandAlone() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 10, face: true, slowFace: true)
        #expect((95...101).contains(c.face))       // 10 Hz: every third frame
        #expect((70...95).contains(c.hand))        // the hand probe is unchanged
        #expect((95...105).contains(c.light))
        var q = FrameRatePlanner()
        let hand = simulate(&q, seconds: 2, face: true, slowFace: true, hand: { _ in true })
        #expect(hand.hand >= 2 * 30 - 4)           // a hand in view still gets every frame
    }

    @Test func fullFaceRateReturnsOnTheNextFrame() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 5, face: true, slowFace: true)
        let first = p.plan(now: 5, forceFull: false, lastFaceSeenAt: 5, slowFace: false)
        #expect(first.runFace)
        let next = p.plan(now: 5 + 1.0 / 30, forceFull: false, lastFaceSeenAt: 5, slowFace: false)
        #expect(next.runFace)
    }

    @Test func forcedFullOverridesSlowFace() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 5, face: true, force: true, slowFace: true)
        #expect(c.hand == 150)
        #expect((148...150).contains(c.face))
    }

    @Test func noFaceStillDropsToTheIdleRateWhileSlow() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 4, face: false, slowFace: true)
        let idle = simulate(&p, from: 4, seconds: 10, face: false, slowFace: true)
        #expect((18...25).contains(idle.face))
    }

    /// Gestures do nothing with another app in front, so a hand in view gets only the probe: about 8 of 30 frames.
    @Test func anotherAppInFrontProbesTheHandWhileAHandIsInView() {
        var claude = FrameRatePlanner()
        let every = simulate(&claude, seconds: 10, face: true, hand: { _ in true })
        var p = FrameRatePlanner()
        let probed = simulate(&p, seconds: 10, face: true, slowFace: true, otherApp: true, hand: { _ in true })
        #expect(every.hand == 300)
        #expect((70...90).contains(probed.hand))   // at most 30% of every frame
        #expect(probed.hand * 10 <= every.hand * 3)
    }

    /// Dictating, a send pending, calibrating, a scroll, a held pinch, the tour's practice, peace open and a pane
    /// resize all reach the planner as `forceFull`, which still wins with another app in front.
    @Test func forcedFullWinsOverAnotherAppInFront() {
        var p = FrameRatePlanner()
        #expect(simulate(&p, seconds: 5, face: true, force: true, slowFace: true, otherApp: true, hand: { _ in true }).hand == 150)
        var q = FrameRatePlanner()
        #expect(simulate(&q, seconds: 5, face: true, force: true, otherApp: true).hand == 150)
        var r = FrameRatePlanner()
        _ = simulate(&r, seconds: 8, face: false, otherApp: true)
        #expect(simulate(&r, from: 8, seconds: 3, face: false, force: true, otherApp: true).hand == 90)
    }

    @Test func everyHandFrameReturnsOnTheFirstFrameBackInClaude() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 5, face: true, slowFace: true, otherApp: true, hand: { _ in true })
        var stayed = p
        #expect(!stayed.plan(now: 5, forceFull: false, lastFaceSeenAt: 5, slowFace: true, otherAppInFront: true).runHand)
        #expect(p.plan(now: 5, forceFull: false, lastFaceSeenAt: 5).runHand)
        #expect(p.plan(now: 5 + 1.0 / 30, forceFull: false, lastFaceSeenAt: 5).runHand)
    }

    @Test func whenTheFaceMayRunSlowly() {
        func slow(full: Bool = false, tour: Bool = false, other: Bool = false, sessions: Bool = true,
                  paused: TimeInterval? = nil) -> Bool {
            FrameRatePlanner.wantsSlowFace(needsFull: full, tourOpen: tour, otherAppInFront: other, sessionsOnScreen: sessions,
                                           pausedFor: paused)
        }
        #expect(!slow())                           // Claude in front with a session: full rate
        #expect(slow(other: true))                 // another app in front
        #expect(slow(sessions: false))             // no Claude session on screen
        #expect(!slow(paused: 2.9))                // a short pause keeps full rate for a quick resume
        #expect(slow(paused: 3))                   // a long one slows
        #expect(!slow(full: true, other: true, sessions: false, paused: 10))   // dictating, sending or a gesture held
        #expect(!slow(tour: true, other: true))    // the tour keeps full rate
    }
}
