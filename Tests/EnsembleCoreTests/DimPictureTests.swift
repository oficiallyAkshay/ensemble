import Testing
@testable import EnsembleCore

@Suite struct DimPictureTests {
    private func run(_ d: DimPicture, luma: Double, from: Double, for seconds: Double, covered: Bool = false, step: Double = 0.1) -> [(t: Double, state: Bool)] {
        var changes: [(Double, Bool)] = []
        var t = from
        while t <= from + seconds + 1e-9 {
            if let s = d.push(FrameLight(t: t, meanLuma: luma, lumaStdDev: 0.05), covered: covered) { changes.append((t, s)) }
            t += step
        }
        return changes
    }

    @Test func dimPictureHeldForSeveralSecondsShowsTheHint() throws {
        let d = DimPicture()
        #expect(run(d, luma: 0.12, from: 0, for: 3.8).isEmpty)
        #expect(!d.dim)
        let changes = run(d, luma: 0.12, from: 3.9, for: 2)
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.state)
        #expect(abs(change.t - 4.0) < 0.11)
        #expect(d.dim)
    }

    @Test func hintClearsAfterASecondOfLight() {
        let d = DimPicture()
        _ = run(d, luma: 0.12, from: 0, for: 5)
        #expect(d.dim)
        #expect(run(d, luma: 0.4, from: 5.1, for: 0.8).isEmpty)
        #expect(d.dim)
        let changes = run(d, luma: 0.4, from: 5.9, for: 1)
        #expect(changes.count == 1 && changes[0].state == false)
        #expect(!d.dim)
    }

    @Test func coveredLensNeverShowsTheHint() {
        let d = DimPicture()
        #expect(run(d, luma: 0.02, from: 0, for: 10, covered: true).isEmpty)
        #expect(!d.dim)
    }

    @Test func coveringWhileTheHintShowsTakesItAway() {
        let d = DimPicture()
        _ = run(d, luma: 0.12, from: 0, for: 5)
        let changes = run(d, luma: 0.02, from: 5.1, for: 1, covered: true)
        #expect(changes.count == 1 && changes[0].state == false)
        #expect(!d.dim)
    }

    @Test func aDarkSpellStartedBeforeTheCoverDoesNotCarryOver() {
        let d = DimPicture()
        _ = run(d, luma: 0.12, from: 0, for: 3)
        _ = run(d, luma: 0.02, from: 3.1, for: 2, covered: true)
        #expect(run(d, luma: 0.12, from: 5.2, for: 3).isEmpty)
        #expect(!d.dim)
    }

    @Test func lightBetweenTheThresholdsHoldsTheState() {
        let d = DimPicture()
        _ = run(d, luma: 0.12, from: 0, for: 5)
        #expect(run(d, luma: 0.18, from: 5.1, for: 5).isEmpty)
        #expect(d.dim)
        let e = DimPicture()
        #expect(run(e, luma: 0.18, from: 0, for: 10).isEmpty)
        #expect(!e.dim)
    }

    @Test func aBrightFrameResetsTheDimTimer() {
        let d = DimPicture()
        _ = run(d, luma: 0.12, from: 0, for: 3)
        _ = run(d, luma: 0.5, from: 3.1, for: 0.1)
        #expect(run(d, luma: 0.12, from: 3.3, for: 3).isEmpty)
        #expect(!d.dim)
    }

    @Test func theHintThresholdSitsAboveTheCoverRule() {
        let cover = CoverDetector()
        var t = 0.0
        while t < 6 { _ = cover.push(FrameLight(t: t, meanLuma: 0.12, lumaStdDev: 0.01)); t += 0.1 }
        #expect(!cover.covered)
    }
}
