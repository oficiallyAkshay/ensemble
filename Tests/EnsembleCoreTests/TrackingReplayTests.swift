import Foundation
import Testing
@testable import EnsembleCore

@Suite struct TrackingReplayTests {
    /// 30 readings a second: still at (100,100) for 3 s, a 0.5 s move to (400,100), still for 3 s, then 1 s with no face and 2 s still.
    private func recording() -> [TrackSample] {
        var s: [TrackSample] = []
        func add(_ t: Double, _ x: Double, faces: Int = 1) {
            let jitter = s.count % 2 == 0 ? 2.0 : -2.0
            s.append(TrackSample(t: t, faces: faces, nose: faces == 1 ? CGPoint(x: x + jitter, y: 100) : nil, luma: 0.25))
        }
        for k in 0..<90 { add(Double(k) / 30, 100) }
        for k in 0..<15 { add(3 + Double(k) / 30, 100 + 600 * Double(k) / 30) }
        for k in 0..<90 { add(3.5 + Double(k) / 30, 400) }
        for k in 0..<30 { add(6.5 + Double(k) / 30, 400, faces: 0) }
        for k in 0..<60 { add(7.5 + Double(k) / 30, 400) }
        return s
    }

    @Test func countsLostFaceShareOfAllReadings() {
        let m = TrackingReplay.metrics(of: recording())
        #expect(m.readings == 285)
        #expect(abs(m.lostFaceRate - 30.0 / 285) < 1e-9)
        #expect(m.meanLuma == 0.25)
    }

    @Test func measuresWanderWhileTheHeadIsStill() throws {
        let wander = try #require(TrackingReplay.metrics(of: recording()).stillWander)
        #expect(abs(wander - 2) < 0.1)
    }

    @Test func measuresTheTimeToFollowAStep() throws {
        let lag = try #require(TrackingReplay.metrics(of: recording()).followLag)
        #expect(lag > 0.3 && lag < 0.5)
    }

    @Test func noisierNoseWandersMore() throws {
        let calm = try #require(TrackingReplay.metrics(of: recording()).stillWander)
        let noisy = recording().enumerated().map { i, s in
            var s = s
            if let n = s.nose { s.nose = CGPoint(x: n.x, y: n.y + (i % 3 == 0 ? 15 : -7.5)) }
            return s
        }
        #expect(try #require(TrackingReplay.metrics(of: noisy).stillWander) > calm * 3)
    }

    @Test func aHeadThatNeverRestsHasNoWanderOrLag() {
        let moving = (0..<120).map { TrackSample(t: Double($0) / 30, faces: 1, nose: CGPoint(x: Double($0) * 20, y: 0)) }
        let m = TrackingReplay.metrics(of: moving)
        #expect(m.stillWander == nil && m.followLag == nil && m.meanLuma == nil)
    }

    @Test func aSmallShiftBetweenRestsIsNotAStep() {
        var s: [TrackSample] = []
        for k in 0..<120 { s.append(TrackSample(t: Double(k) / 30, faces: 1, nose: CGPoint(x: k < 60 ? 0 : 50, y: 0))) }
        #expect(TrackingReplay.metrics(of: s).followLag == nil)
    }

    @Test func aStepAfterALongGapIsNotFollowed() {
        var s: [TrackSample] = []
        for k in 0..<60 { s.append(TrackSample(t: Double(k) / 30, faces: 1, nose: CGPoint(x: 0, y: 0))) }
        for k in 0..<60 { s.append(TrackSample(t: 10 + Double(k) / 30, faces: 1, nose: CGPoint(x: 500, y: 0))) }
        let m = TrackingReplay.metrics(of: s)
        #expect(m.stillWander != nil && m.followLag == nil)
    }

    @Test func aJumpBetweenRestsIsAStepWithAlmostNoLag() throws {
        var s: [TrackSample] = []
        for k in 0..<60 { s.append(TrackSample(t: Double(k) / 30, faces: 1, nose: CGPoint(x: 0, y: 0))) }
        for k in 0..<60 { s.append(TrackSample(t: 2 + Double(k) / 30, faces: 1, nose: CGPoint(x: 0, y: 150))) }
        let lag = try #require(TrackingReplay.metrics(of: s).followLag)
        #expect(lag < 0.1)
    }

    @Test func emptyRecordingHasNoNumbers() {
        let m = TrackingReplay.metrics(of: [])
        #expect(m.readings == 0 && m.stillWander == nil && m.followLag == nil && m.meanLuma == nil)
    }

    @Test func traceLinesRoundTripAndOtherLinesAreIgnored() {
        let samples = [
            TrackSample(t: 1.5, faces: 1, nose: CGPoint(x: 612, y: 340), luma: 0.231),
            TrackSample(t: 1.533, faces: 0, nose: nil, luma: nil),
            TrackSample(t: 1.567, faces: 2, nose: nil, luma: 0.1),
        ]
        let text = "0.500 head nose=1,2 under=- faces=1\n" + samples.map { String(format: "%.3f ", $0.t) + $0.traceLine }.joined(separator: "\n") + "\nnot a trace line\n"
        let parsed = TrackingReplay.samples(fromTrace: text)
        #expect(parsed.map(\.faces) == [1, 0, 2])
        #expect(parsed[0].nose == CGPoint(x: 612, y: 340) && parsed[0].luma == 0.231)
        #expect(parsed[1].nose == nil && parsed[1].luma == nil)
        #expect(abs(parsed[2].t - 1.567) < 1e-9)
        #expect(samples[0].traceLine == "read faces=1 nose=612,340 luma=0.231")
        #expect(samples[1].traceLine == "read faces=0 nose=- luma=-")
    }

    /// Prints the three numbers for saved trace files named in ENSEMBLE_TRACE_FILES (comma separated, full paths);
    /// does nothing otherwise. Run: ENSEMBLE_TRACE_FILES=$HOME/trace-good.log,$HOME/trace-dim.log swift test --filter TrackingReplayTests/printsTheNumbersOfSavedTraces
    @Test func printsTheNumbersOfSavedTraces() throws {
        guard let list = ProcessInfo.processInfo.environment["ENSEMBLE_TRACE_FILES"] else { return }
        for path in list.split(separator: ",") {
            let m = TrackingReplay.metrics(of: TrackingReplay.samples(fromTrace: try String(contentsOfFile: String(path), encoding: .utf8)))
            func f(_ v: Double?, _ unit: String) -> String { v.map { String(format: "%.2f", $0) + unit } ?? "no data" }
            print("\(path): \(m.readings) readings, face lost \(String(format: "%.1f", m.lostFaceRate * 100)) percent, wander while still \(f(m.stillWander, " pt")), follow lag \(f(m.followLag, " s")), mean brightness \(f(m.meanLuma, ""))")
        }
    }
}
