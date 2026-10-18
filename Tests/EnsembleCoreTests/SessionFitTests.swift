import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct SessionFitTests {
    @Test func theNarrowPaneTakesItsWidthThroughOneDivider() throws {
        // No pane is wider than the column: the next pane gives it all, so one divider moves.
        let w = try #require(SessionFit.widths(current: [400, 800, 800], focus: 0, width: 840))
        #expect(w == [840, 360, 800])
    }

    @Test func theOwnersRowTakesFromTheWidePaneAndLeavesTheFirstAlone() throws {
        // 0.2.20: [565, 320, 1674] fitting the middle pane took from both sides and left the first at the minimum.
        let want = SessionFit.fitWidth(paneColumn: 832)
        let w = try #require(SessionFit.widths(current: [565, 320, 1674], focus: 1, width: want, keep: 832, minimum: 319))
        #expect(w[0] == 565)
        #expect(abs(w[1] - want) < 0.001)
        #expect(abs(w[2] - (1674 - (want - 320))) < 0.001)
        #expect(w[2] >= 832)
        // One divider moves, in one burst.
        let presses = PaneKeys.plan(from: [565, 320, 1674], to: w, minimum: 319)
        #expect(Set(presses.map(\.divider)) == [1])
        #expect(presses.count <= 22)
        #expect(PaneKeys.duration(presses) < 0.15)
    }

    @Test func theTargetIsTenPercentOverTheColumnAndNeverMore() throws {
        #expect(abs(SessionFit.fitWidth(paneColumn: 832) - 915.2) < 0.001)
        let w = try #require(SessionFit.widths(current: [400, 2000], focus: 0, width: 915.2, keep: 832))
        #expect(abs(w[0] - 915.2) < 0.001)
    }

    /// The peace sign asks for the same width as the rest on a narrow session, with no earlier fit held (`floors: []`).
    @Test(arguments: [
        ([700.0, 1820], 0, [915.2, 1604.8]),
        ([600.0, 600, 1320], 0, [915.2, 600, 1004.8]),
        ([630.0, 630, 630, 630], 3, [630, 630, 344.8, 915.2]),
    ] as [([Double], Int, [Double])])
    func thePeaceSignWidensToTheChatWidthAndTakesNoMoreThanItNeeds(_ row: [Double], _ k: Int, _ planned: [Double]) throws {
        let want = SessionFit.fitWidth(paneColumn: 832)
        let w = try #require(SessionFit.restingFit(current: row, focus: k, width: want, keep: 832, minimum: 316, floors: []))
        for (a, b) in zip(w, planned) { #expect(abs(a - b) < 0.001, "\(w)") }
        #expect(abs(w.reduce(0, +) - row.reduce(0, +)) < 0.001)
        #expect(w.enumerated().allSatisfy { $0.offset == k || $0.element >= 316 })
        // The keys land the session within one arrow of the plan.
        let presses = PaneKeys.plan(from: row, to: w, minimum: 316)
        #expect(abs(PaneKeys.simulate(row, minimum: 316, presses: presses)[k] - want) <= PaneKeys.arrow)
    }

    @Test func thePeaceSignDoesNothingToASessionAlreadyWiderThanTheChatWidth() {
        for (row, k) in [([1000.0, 1520], 0), ([1000.0, 500, 1020], 0), ([1000.0, 500, 500, 520], 0)] {
            #expect(SessionFit.restingFit(current: row, focus: k, width: 915.2, keep: 832, minimum: 316, floors: []) == nil)
        }
    }

    @Test func theWiderSideGivesWhenBothNeighboursCould() throws {
        let w = try #require(SessionFit.widths(current: [1000, 400, 1400], focus: 1, width: 900, keep: 832))
        #expect(w == [1000, 900, 900])
        let left = try #require(SessionFit.widths(current: [1400, 400, 1000], focus: 1, width: 900, keep: 832))
        #expect(left == [900, 900, 1000])
    }

    @Test func aFarWidePaneGivesWhenTheNeighbourIsAtTheColumn() throws {
        // The neighbour is at the column; the pane after it has room above it: two dividers, the neighbour unchanged.
        let w = try #require(SessionFit.widths(current: [500, 840, 1600], focus: 0, width: 900, keep: 832))
        #expect(w == [900, 840, 1200])
    }

    @Test func panesGoUnderTheColumnOnlyWhenTheRowLeavesNoOtherWay() throws {
        // Nothing above the column anywhere: the neighbour gives down to the minimum before a second divider moves.
        let w = try #require(SessionFit.widths(current: [600, 700, 700], focus: 0, width: 900, keep: 832, minimum: 320))
        #expect(w == [900, 400, 700])
    }

    @Test func aPaneAlreadyWideEnoughIsLeftAlone() {
        #expect(SessionFit.widths(current: [900, 800, 800], focus: 0, width: 840) == nil)
        #expect(SessionFit.widths(current: [836, 800], focus: 0, width: 840) == nil)
    }

    @Test func noPaneGoesBelowTheMinimumAndTheRestShareWhatIsLeft() throws {
        // The middle pane can give 50; the last gives the remaining 350.
        let w = try #require(SessionFit.widths(current: [440, 350, 1000], focus: 0, width: 840))
        #expect(w == [840, 300, 650])
    }

    @Test func whenTheOthersRunOutThePaneGetsWhatTheyHave() throws {
        let w = try #require(SessionFit.widths(current: [300, 400, 400], focus: 0, width: 840))
        #expect(w == [500, 300, 300])
        #expect(SessionFit.widths(current: [300, 300, 300], focus: 1, width: 840) == nil)
    }

    @Test func badInputPlansNothing() {
        #expect(SessionFit.widths(current: [400], focus: 0, width: 840) == nil)
        #expect(SessionFit.widths(current: [400, 800], focus: 2, width: 840) == nil)
        #expect(SessionFit.widths(current: [400, .nan], focus: 0, width: 840) == nil)
    }

    @Test func theFitPlanSettlesOnARowLikeClaudes() throws {
        // Four 630 pt panes 10 pt apart, the second widened to 832: one neighbour gives it, the row keeps its total.
        let panes = [0.0, 640, 1280, 1920].map { CGRect(x: $0, y: 30, width: 630, height: 1300) }
        let dividers = [635.0, 1275, 1915]
        let (widths, _) = PaneWidths.layout(panes: panes, dividers: dividers)
        #expect(widths == [630, 630, 630, 630])
        let fit = try #require(SessionFit.widths(current: widths, focus: 1, width: 832))
        #expect(abs(fit[1] - 832) < 0.001)
        #expect(fit.filter { abs($0 - 630) < 0.001 }.count == 2)
        #expect(abs(fit.reduce(0, +) - 2520) < 0.001)
    }

    @Test func theTriggerFiresOnceAfterTheNoseRests() {
        var t = SessionFit.Trigger()
        #expect(t.observe("a", inside: true, at: 0) == nil)
        #expect(t.observe("a", inside: true, at: 0.7) == nil)
        #expect(t.observe("a", inside: true, at: 0.8) == "a")
        #expect(t.observe("a", inside: true, at: 2) == nil)
    }

    @Test func passingOverASessionNeverFitsIt() {
        var t = SessionFit.Trigger()
        #expect(t.observe("a", inside: true, at: 0) == nil)
        #expect(t.observe("b", inside: true, at: 0.3) == nil)
        #expect(t.observe("a", inside: true, at: 0.7) == nil)
        #expect(t.observe(nil, inside: false, at: 1.0) == nil)
        #expect(t.observe(nil, inside: false, at: 5) == nil)
        #expect(t.observe("b", inside: true, at: 5.1) == nil)
        #expect(t.observe("b", inside: true, at: 5.9) == "b")
    }

    @Test func focusHeldWithTheNoseOutsideIsNoRest() {
        // The focus stays on a while the nose crosses its edge into the next session: the wait starts again once
        // the nose is back inside, so a session the nose is leaving is not fitted.
        var t = SessionFit.Trigger()
        #expect(t.observe("a", inside: true, at: 0) == nil)
        #expect(t.observe("a", inside: false, at: 0.5) == nil)
        #expect(t.observe("a", inside: false, at: 1.5) == nil)
        #expect(t.observe("a", inside: true, at: 1.6) == nil)
        #expect(t.observe("a", inside: true, at: 2.3) == nil)
        #expect(t.observe("a", inside: true, at: 2.5) == "a")
    }

    @Test func aFitThatCouldNotRunIsAskedForAgainOnlyWhileTheNoseRests() {
        var t = SessionFit.Trigger()
        _ = t.observe("a", inside: true, at: 0)
        #expect(t.observe("a", inside: true, at: 1) == "a")
        t.retry()
        #expect(t.waiting(for: "a"))
        #expect(t.observe("a", inside: true, at: 1.05) == "a")
        t.retry()
        // Focus moved on: the old session is never fitted, the new one after its own rest.
        #expect(t.observe("b", inside: true, at: 1.1) == nil)
        #expect(t.observe("b", inside: true, at: 2.0) == "b")
    }

    @Test func theTriggerWaitsUntilItHasAnsweredForTheFocus() {
        var t = SessionFit.Trigger()
        #expect(!t.waiting(for: nil))
        #expect(t.waiting(for: "a"))
        _ = t.observe("a", inside: true, at: 0)
        #expect(t.waiting(for: "a"))
        _ = t.observe("a", inside: true, at: 1)
        #expect(!t.waiting(for: "a"))
        #expect(t.waiting(for: "b"))
        #expect(!t.waiting(for: nil))
    }

    @Test func comingBackToASessionIsANewFocusChange() {
        var t = SessionFit.Trigger()
        _ = t.observe("a", inside: true, at: 0)
        #expect(t.observe("a", inside: true, at: 1) == "a")
        _ = t.observe("b", inside: true, at: 2)
        _ = t.observe("a", inside: true, at: 3)
        #expect(t.observe("a", inside: true, at: 3.9) == "a")
    }
}

@Suite struct ChatColumnTests {
    let transcript = CGRect(x: 100, y: 40, width: 1200, height: 1200)

    @Test func theCentredColumnInAWidePaneIsRead() {
        let column = CGRect(x: 100 + (1200 - 832) / 2, y: 60, width: 832, height: 400)
        let text = CGRect(x: column.minX + 32, y: 60, width: 768, height: 100)
        let row = CGRect(x: 100, y: 60, width: 1200, height: 400)
        #expect(ChatColumn.measure(transcript: transcript, elements: [row, column, text]) == 832)
    }

    @Test func aPaneNarrowerThanTheColumnShowsNone() {
        let narrow = CGRect(x: 0, y: 40, width: 700, height: 1200)
        let text = CGRect(x: 32, y: 60, width: 636, height: 100)
        #expect(ChatColumn.measure(transcript: narrow, elements: [narrow, text]) == nil)
    }

    @Test func offCentreOrOddSizedElementsAreNotTheColumn() {
        let card = CGRect(x: 120, y: 60, width: 700, height: 100)
        let bubble = CGRect(x: 100 + (1200 - 500) / 2, y: 60, width: 500, height: 100)
        #expect(ChatColumn.measure(transcript: transcript, elements: [card, bubble]) == nil)
    }

    @Test func thePaneWidthAddsWhatSitsBesideTheTranscript() {
        let pane = CGRect(x: 0, y: 30, width: 600, height: 1300)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: CGRect(x: 4, y: 40, width: 592, height: 1200)) == 840)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: nil) == 832)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: CGRect(x: 0, y: 40, width: 900, height: 10)) == 832)
    }

    @Test func memoryTakesClaudesOwnColumnsAndFallsBack() {
        var m = ChatColumn.Memory()
        #expect(m.width == SessionFit.fallbackColumn)
        m.note([nil, nil], panes: [600, 600])
        #expect(m.measured == nil)
        m.note([nil, 1024, 832], panes: [600, 1300, 1000])
        #expect(m.width == 1024)
        // The widest reliable reading is kept, never simply the latest.
        m.note([832], panes: [1000])
        #expect(m.width == 1024)
    }

    @Test func aReadingThatFollowsThePaneWidthIsNotTheColumn() {
        // Measured 2026-10-15: panes of 864 and 774 pt read 736 and 646, their own width less 128.
        var m = ChatColumn.Memory()
        m.note([736], panes: [864])
        m.note([646], panes: [774])
        m.note([700], panes: [828])
        #expect(m.measured == nil)
        #expect(m.width == 832)
    }

    @Test func aTextMeasureReadingIsTheColumnWithItsGutters() {
        // 0.2.20: panes 1674 and 1392 pt wide both read 773, the 768 pt text without its gutters.
        var m = ChatColumn.Memory()
        m.note([773], panes: [1674])
        m.note([773], panes: [1392])
        #expect(m.width == 832)
        // Never narrower than Claude's narrowest column.
        var n = ChatColumn.Memory()
        n.note([700], panes: [1000])
        n.note([700], panes: [1300])
        #expect(n.width == 832)
    }

    @Test func anUnknownColumnCountsOnceTwoPaneWidthsAgree() {
        var m = ChatColumn.Memory()
        m.note([900], panes: [1100])
        #expect(m.measured == nil)
        // Same width read from a pane only 20 pt different: still not proof.
        m.note([900], panes: [1120])
        #expect(m.measured == nil)
        m.note([901], panes: [1300])
        #expect(m.measured == 901)
    }
}

@Suite struct SessionFitHoldTests {
    private let never = -Double.infinity

    @Test func perPaneFloorsKeepAFittedPane() throws {
        // Pane 0 was fitted to 832; fitting pane 2 may take from panes 1 and 3 only.
        let w = try #require(SessionFit.widths(current: [832, 600, 500, 588], focus: 2, width: 832, floors: [832, 0, 0, 0]))
        #expect(w[0] == 832)
        #expect(abs(w[2] - 832) < 0.001)
        #expect(abs(w[1] - 434) < 0.001 && abs(w[3] - 422) < 0.001)
    }

    @Test func aRecentFitIsKeptWhileTheOthersCanGiveTheWidth() throws {
        var hold = SessionFit.Hold()
        let ids = ["a", "b", "c", "d"]
        let row = [630.0, 630, 630, 630]
        let first = try #require(SessionFit.restingFit(current: row, focus: 0, width: 832, floors: hold.floors(ids, focus: 0, now: 10)))
        #expect(abs(first[0] - 832) < 0.001)
        hold.noteFit("a", width: 832, narrowed: ["b", "c", "d"], at: 10)
        // Resting on d a moment later: a keeps its fit, b and c give the width.
        let f = hold.floors(ids, focus: 3, now: 20)
        #expect(f == [832, 0, 0, 0])
        let second = try #require(SessionFit.restingFit(current: first, focus: 3, width: 832, floors: f))
        #expect(abs(second[0] - 832) < 0.001 && abs(second[3] - 832) < 0.001)
    }

    @Test func theSessionYouRestOnIsFittedEvenWhenARecentFitHeldIt() throws {
        // b was narrowed by a's fit a few seconds ago and the others cannot give enough without undoing a's fit:
        // resting on b still fits it, every other pane giving its share (0.2.18 refused it for three minutes).
        var hold = SessionFit.Hold()
        let ids = ["a", "b", "c"]
        hold.noteFit("a", width: 1000, narrowed: ["b", "c"], at: 10)
        #expect(hold.refusal(now: 15, calibratedAt: never) == nil)
        let f = hold.floors(ids, focus: 1, now: 15)
        #expect(f == [1000, 0, 0])
        let w = try #require(SessionFit.restingFit(current: [1000, 400, 400], focus: 1, width: 832, floors: f))
        #expect(abs(w[1] - 832) < 0.001)
        #expect(w[0] < 1000 && abs(w.reduce(0, +) - 1800) < 0.001)
    }

    @Test func nothingIsFittedJustAfterCalibration() {
        let hold = SessionFit.Hold()
        #expect(hold.refusal(now: 103, calibratedAt: 100) != nil)
        #expect(hold.refusal(now: 106, calibratedAt: 100) == nil)
        #expect(hold.refusal(now: 106, calibratedAt: -.infinity) == nil)
    }

    @Test func anAskedForLayoutClearsTheHold() {
        var hold = SessionFit.Hold()
        hold.noteFit("a", width: 832, narrowed: ["b"], at: 10)
        hold.reset()
        #expect(hold.floors(["a", "b"], focus: 1, now: 11) == [0, 0])
    }

    @Test func aPaneNarrowedByALaterFitNoLongerKeepsItsFit() {
        var hold = SessionFit.Hold()
        hold.noteFit("a", width: 832, narrowed: ["b"], at: 10)
        hold.noteFit("b", width: 832, narrowed: ["a"], at: 300)
        #expect(hold.floors(["a", "b"], focus: 0, now: 301) == [0, 832])
    }
}
