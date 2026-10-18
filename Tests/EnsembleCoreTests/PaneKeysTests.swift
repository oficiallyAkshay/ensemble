import Foundation
import Testing
@testable import EnsembleCore

/// The planner against a simulated Claude row: each press moves only the pair beside its divider and stops at
/// Claude's own minimum, which the planner only estimates.
@Suite struct PaneKeysTests {
    /// Claude's minimum on the owner's Mac: 24 percent of a 1320 pt pair.
    private let claudeMin = 316.0

    /// Plans, runs the presses on the simulated row and returns where the row ends up.
    private func run(_ w: [Double], to target: [Double], estimate: Double? = nil) -> (widths: [Double], presses: [PaneKeys.Press]) {
        let presses = PaneKeys.plan(from: w, to: target, minimum: estimate ?? claudeMin)
        return (PaneKeys.simulate(w, minimum: claudeMin, presses: presses), presses)
    }

    @Test(arguments: [0, 1, 2, 3])
    func evenOutAfterOneSessionTookTheWidthReturnsToEqualWidths(_ k: Int) throws {
        let maxed = (0..<4).map { $0 == k ? 2520 - 3 * claudeMin : claudeMin }
        let (w, presses) = run(maxed, to: try #require(PaneKeys.evenWidths(maxed)))
        for x in w { #expect(abs(x - 630) <= PaneKeys.arrow) }
        // A divider jumps to a limit only when its target is nearer that limit than the divider is: from a pane
        // maximized at either end, the first divider's target is.
        #expect(presses.count <= 45)
        if k == 0 || k == 3 { #expect(presses.contains { $0.key == .home || $0.key == .end }) }
    }

    @Test func aSmallMoveIsShiftStepsAndAFewArrows() {
        // A 104 pt fit: three Shift steps and one arrow, sent as one burst.
        let presses = PaneKeys.plan(from: [728, 896], to: [832, 792], minimum: claudeMin, jumps: false)
        #expect(presses.map(\.key) == [.shiftRight, .shiftRight, .shiftRight, .right])
        #expect(PaneKeys.duration(presses) <= 0.05)
        #expect(abs(PaneKeys.simulate([728, 896], minimum: claudeMin, presses: presses)[0] - 832) <= PaneKeys.arrow / 2)
    }

    @Test func everyPlanVisitsEachDividerOnceWithFewArrows() throws {
        let rows: [[Double]] = [[316, 1572, 316, 316], [630, 630, 630, 630], [1000, 400, 700, 420], [316, 316, 316, 316, 1256]]
        for row in rows {
            let targets = [try #require(PaneKeys.evenWidths(row))]
                + row.indices.compactMap { SessionFit.widths(current: row, focus: $0, width: 832, minimum: claudeMin) }
            for target in targets {
                for jumps in [true, false] {
                    let presses = PaneKeys.plan(from: row, to: target, minimum: claudeMin, jumps: jumps)
                    // One burst per divider: its keys are contiguous.
                    var seen: [Int] = []
                    for p in presses where seen.last != p.divider {
                        #expect(!seen.contains(p.divider))
                        seen.append(p.divider)
                    }
                    for d in seen {
                        let keys = presses.filter { $0.divider == d }.map(\.key)
                        #expect(keys.filter { $0 == .left || $0 == .right }.count <= 3)
                    }
                    let w = PaneKeys.simulate(row, minimum: claudeMin, presses: presses)
                    for i in w.indices { #expect(abs(w[i] - target[i]) <= PaneKeys.arrow + 0.001, "\(row) to \(target)") }
                }
            }
        }
    }

    @Test func aLongMoveJumpsThenSteps() {
        // 2020 pt in a two-pane row: a glide would need 64 keys; End then two Shift steps back is three.
        let presses = PaneKeys.plan(from: [400, 2400], to: [2420, 380], minimum: claudeMin)
        #expect(presses.map(\.key) == [.end, .shiftLeft, .shiftLeft])
        let w = PaneKeys.simulate([400, 2400], minimum: claudeMin, presses: presses)
        #expect(abs(w[0] - 2420) <= PaneKeys.arrow / 2)
        // A move that ends on a limit is one key, however far.
        #expect(PaneKeys.plan(from: [1260, 1260], to: [316, 2204], minimum: claudeMin) == [.init(0, .home)])
    }

    @Test func aFitPlanReachesTheChatColumn() throws {
        let row = [630.0, 630, 630, 630]
        let fit = try #require(SessionFit.widths(current: row, focus: 1, width: 832))
        let (w, presses) = run(row, to: fit)
        #expect(abs(w[1] - 832) <= PaneKeys.arrow)
        #expect(abs(w.reduce(0, +) - 2520) < 0.001)
        #expect(presses.count <= 12)
    }

    @Test func nothingToDoIsNoPresses() {
        #expect(PaneKeys.plan(from: [850, 850, 850], to: [852, 849, 849], minimum: claudeMin).isEmpty)
    }

    @Test func badInputPlansNothing() {
        #expect(PaneKeys.plan(from: [850, 850], to: [850, 850, 850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, 850], to: [800, 800], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, .nan], to: [850, 850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850], to: [850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, 850], to: [900, 800], minimum: .nan).isEmpty)
        #expect(PaneKeys.evenWidths([850]) == nil)
    }

    @Test func claudesMinimumIsReadFromTheDividers() {
        // Measured: pairs of 1320 and 1256 pt reporting 24 and 26 percent.
        #expect(abs(PaneKeys.minimum(pairWidths: [1320, 1256], minPercents: [24, 26]) - 326.56) < 0.01)
        #expect(PaneKeys.minimum(pairWidths: [1320], minPercents: [nil]) == PaneKeys.fallbackMinimum)
        #expect(PaneKeys.minimum(pairWidths: [1320], minPercents: [0]) == PaneKeys.fallbackMinimum)
    }

    @Test func stepsRoundToTheNearestArrow() {
        #expect(PaneKeys.stepKeys(40) == [.shiftRight, .right])
        #expect(PaneKeys.stepKeys(-60) == [.shiftLeft, .shiftLeft])
        #expect(PaneKeys.stepKeys(3) == [])
        // Never more than two arrows: three arrows' worth is one more Shift step and one arrow back.
        #expect(PaneKeys.stepKeys(24) == [.shiftRight, .left])
        #expect(PaneKeys.stepKeys(-88) == [.shiftLeft, .shiftLeft, .shiftLeft, .right])
    }

    @Test func aTargetNearerTheLimitStartsWithHomeOrEnd() {
        // 900 pt right in a 2400 pt pair: the target sits 184 pt from End, nearer than the 900 pt glide.
        let near = PaneKeys.moveKeys(from: 600, to: 1500, lo: 316, hi: 1684, jumps: true)
        #expect(near.first == .end)
        #expect(near.count < PaneKeys.stepKeys(900).count)
        // Nearer where it is than to the limit: Shift steps only.
        #expect(!PaneKeys.moveKeys(from: 600, to: 900, lo: 316, hi: 1684, jumps: true).contains(.end))
    }

    @Test func homeAndEndStopAtClaudesMinimum() {
        let w = PaneKeys.simulate([800, 800], minimum: 316, presses: [.init(0, .end)])
        #expect(w == [1284, 316])
        #expect(PaneKeys.simulate(w, minimum: 316, presses: [.init(0, .right)]) == [1284, 316])
        // A divider that does not exist moves nothing.
        #expect(PaneKeys.simulate(w, minimum: 316, presses: [.init(3, .home)]) == w)
    }
}
