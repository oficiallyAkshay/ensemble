import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct DotSpringTests {
    @Test func coversNinetyPercentOfAStepWithinOneThirtyMilliseconds() {
        var s = DotSpring()
        s.reset(to: .zero)
        let goal = CGPoint(x: 300, y: 0)
        var t = 0.0
        while s.position!.x < 270, t < 1 { s.step(toward: goal, dt: 1.0 / 60); t += 1.0 / 60 }
        #expect(t <= 0.135)
    }

    @Test func neverOvershootsTheGoal() {
        var s = DotSpring()
        s.reset(to: .zero)
        let goal = CGPoint(x: 300, y: -120)
        for _ in 0..<120 {
            let p = s.step(toward: goal, dt: 1.0 / 60)
            #expect(p.x <= 300 + 1e-9 && p.y >= -120 - 1e-9)
        }
        #expect(s.isResting(at: goal))
    }

    @Test func aLateRefreshLandsWhereSmallStepsWould() {
        var fine = DotSpring(), coarse = DotSpring()
        fine.reset(to: .zero); coarse.reset(to: .zero)
        let goal = CGPoint(x: 100, y: 50)
        for _ in 0..<6 { fine.step(toward: goal, dt: 1.0 / 60) }
        coarse.step(toward: goal, dt: 6.0 / 60)
        #expect(abs(fine.position!.x - coarse.position!.x) < 1e-6)
        #expect(abs(fine.position!.y - coarse.position!.y) < 1e-6)
    }

    @Test func carriesItsSpeedIntoTheNextReading() {
        // A goal that keeps moving: the dot never comes to a stop between readings (no stepping).
        var s = DotSpring()
        s.reset(to: .zero)
        var goal = CGPoint.zero
        var lastX = 0.0
        for frame in 1...60 {
            if frame % 2 == 0 { goal.x += 20 }       // 30 Hz readings, 60 Hz refresh, 600 pt/s
            let x = Double(s.step(toward: goal, dt: 1.0 / 60).x)
            if frame > 10 { #expect(x - lastX > 2) }
            lastX = x
        }
    }

    @Test func aNonFiniteGoalOrTimeIsIgnoredSafely() {
        var s = DotSpring()
        s.reset(to: CGPoint(x: 10, y: 10))
        #expect(s.step(toward: CGPoint(x: 20, y: 20), dt: .nan) == CGPoint(x: 10, y: 10))
        #expect(s.step(toward: CGPoint(x: CGFloat.nan, y: 0), dt: 1.0 / 60) == CGPoint(x: 10, y: 10))
        #expect(s.position == CGPoint(x: 10, y: 10))
        #expect(s.velocity == .zero)
    }

    @Test func isFastOnlyAboveTheFastSpeed() {
        var s = DotSpring()
        s.reset(to: .zero)
        #expect(!s.isFast)
        s.step(toward: CGPoint(x: 300, y: 0), dt: 1.0 / 60)
        #expect(s.isFast)
        for _ in 0..<60 { s.step(toward: CGPoint(x: 300, y: 0), dt: 1.0 / 60) }
        #expect(!s.isFast)
    }
}

@Suite struct DotLeadTests {
    /// Moving right and down at 1000 pt/s, read at t = 10 s, the next reading expected 33 ms later.
    private func lead(velocity: DotVelocity = DotVelocity(dx: 1000, dy: 500), aim: CGPoint = CGPoint(x: 500, y: 300),
                      interval: TimeInterval = 1.0 / 30) -> DotLead {
        DotLead(point: CGPoint(x: 100, y: 100), t: 10, velocity: velocity, aim: aim, interval: interval)
    }

    @Test func neverLeadsMoreThanFortyMilliseconds() {
        let l = lead()
        for ms in stride(from: -50.0, through: 200, by: 1) {
            let now = 10 + ms / 1000
            #expect(l.lead(at: now) <= 0.04 + 1e-12)
            let g = l.goal(at: now)
            #expect(g.x - 100 <= 1000 * 0.04 + 1e-9 && g.y - 100 <= 500 * 0.04 + 1e-9)
        }
        #expect(abs(l.lead(at: 10) - 0.04) < 1e-12)
        #expect(l.goal(at: 10) == CGPoint(x: 140, y: 120))
    }

    @Test func fadesToTheReadingByTheNextReading() {
        let l = lead()
        var last = l.lead(at: 10)
        for ms in 1...33 {
            let now = 10 + Double(ms) / 1000
            #expect(l.lead(at: now) <= last)
            last = l.lead(at: now)
        }
        #expect(l.lead(at: 10 + 1.0 / 30) < 1e-12)
        #expect(hypot(l.goal(at: 10 + 1.0 / 30).x - 100, l.goal(at: 10 + 1.0 / 30).y - 100) < 1e-9)
        #expect(l.goal(at: 12) == CGPoint(x: 100, y: 100))
    }

    @Test func isOffWhileTheNoseIsStill() {
        let l = lead(velocity: DotVelocity(dx: 30, dy: -20))
        #expect(l.lead(at: 10) == 0)
        #expect(l.goal(at: 10) == CGPoint(x: 100, y: 100))
        #expect(lead(interval: 0).goal(at: 10) == CGPoint(x: 100, y: 100))
    }

    @Test func neverRunsPastTheUnfilteredReading() {
        // The unfiltered reading is 10 pt ahead across and already behind down: the goal stops at it across and keeps the reading down.
        let l = lead(aim: CGPoint(x: 110, y: 95))
        #expect(l.goal(at: 10) == CGPoint(x: 110, y: 100))
        let left = lead(velocity: DotVelocity(dx: -1000, dy: -500), aim: CGPoint(x: 90, y: 0))
        #expect(left.goal(at: 10) == CGPoint(x: 90, y: 80))
    }
}

/// The pointer as the eye sees it: NosePointer's filter, the dot's rest rule and the spring at 60 or 120 Hz, fed 30 head
/// readings a second with seeded noise. The same pipeline `perfbench pointer` measures.
@Suite struct PointerFeelTests {
    private struct Noise {
        var state: UInt64
        mutating func gaussian() -> Double {
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// Yaw to points: x = 2400 yaw + 960, pitch to y = 2000 pitch + 540.
    private func pointer() -> NosePointer {
        let p = NosePointer()
        var samples: [CalibrationSample] = []
        for yaw in [-0.25, 0, 0.25] {
            for pitch in [-0.15, 0, 0.15] {
                samples.append(CalibrationSample(yaw: yaw, pitch: pitch, target: CGPoint(x: 2400 * yaw + 960, y: 2000 * pitch + 540)))
            }
        }
        p.fit(samples)
        p.setSmoothing(PointerSmoothing.defaultLevel)
        return p
    }

    /// Drawn dot positions for `seconds`, with the true yaw from `aim`, the first reading `phase` of a reading late.
    /// `lead` aims the spring as the app does (`DotLead` while the rest rule lets the dot move); on a 120 Hz `display`
    /// a slow dot is redrawn on every second refresh only, as GlassDot asks.
    private func run(seconds: Double, noise: Double, seed: UInt64, phase: Double = 0, display: Double = 60, lead: Bool = false,
                     aim: (Double) -> Double) -> [(t: Double, dot: CGPoint)] {
        var rng = Noise(state: seed)
        let ptr = pointer()
        var rest = NoseDot()
        var spring = DotSpring()
        var goal: CGPoint?
        var ahead: DotLead?
        var next = phase / 30
        var lastTick: Double?
        var out: [(Double, CGPoint)] = []
        for f in 0..<Int(seconds * display) {
            let t = Double(f) / display
            while next <= t {
                let h = HeadObservation(t: next, yaw: aim(next) + noise * rng.gaussian(), pitch: noise * rng.gaussian(), faceCount: 1)
                if let p = ptr.point(for: h) {
                    goal = rest.follow(nose: p, at: next)
                    ahead = lead && rest.moving ? DotLead(point: p, t: next, velocity: ptr.velocity, aim: ptr.aim ?? p, interval: 1.0 / 30) : nil
                }
                next += 1.0 / 30
            }
            guard let g = goal else { continue }
            if display > 60, !spring.isFast, f % 2 == 1 { continue }
            if spring.position == nil { spring.reset(to: g) }
            out.append((t, spring.step(toward: ahead?.goal(at: t) ?? g, dt: t - (lastTick ?? t - 1 / display))))
            lastTick = t
        }
        return out
    }

    /// The mean time (s) over 16 seeds and reading phases to cover 90% of a 300 pt step.
    private func stepLag(display: Double, lead: Bool) -> Double {
        let seeds = 16
        return (0..<seeds).map { s in
            let dots = run(seconds: 4, noise: 0.004, seed: UInt64(s + 1), phase: Double(s) / Double(seeds), display: display, lead: lead) {
                $0 < 2 ? 0 : 300.0 / 2400
            }
            return (dots.first { $0.t >= 2 && Double($0.dot.x) >= 960 + 0.9 * 300 }?.t ?? 4) - 2
        }.reduce(0, +) / Double(seeds)
    }

    /// The mean RMS (pt per frame) of the dot's frame-to-frame step about its mean while panning at 600 pt/s, as `perfbench pointer` counts judder.
    private func panJudder(display: Double, lead: Bool) -> Double {
        let seeds = 16
        return (0..<seeds).map { s in
            let dots = run(seconds: 3, noise: 0.004, seed: UInt64(s + 1), phase: Double(s) / Double(seeds), display: display, lead: lead) {
                $0 < 1.5 ? 0 : ($0 - 1.5) * 600 / 2400
            }.filter { $0.t >= 1.8 && $0.t <= 2.8 }
            let steps = zip(dots.dropFirst(), dots).map { Double($0.dot.x - $1.dot.x) }
            let mean = steps.reduce(0, +) / Double(steps.count)
            return (steps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steps.count)).squareRoot()
        }.reduce(0, +) / Double(seeds)
    }

    @Test(arguments: [60.0, 120.0])
    func theLeadCoversAStepAtLeastThirtyMillisecondsSooner(display: Double) {
        let alone = stepLag(display: display, lead: false), led = stepLag(display: display, lead: true)
        #expect(alone - led >= 0.03, "\(Int(display)) Hz: \(Int(alone * 1000)) ms alone, \(Int(led * 1000)) ms with the lead")
    }

    @Test(arguments: [60.0, 120.0])
    func theLeadsPanJudderCostStaysUnderTwiceTheSpringsAlone(display: Double) {
        // The lead speeds the dot up as the nose does, which the judder figure counts; this pins the accepted cost.
        let alone = panJudder(display: display, lead: false), led = panJudder(display: display, lead: true)
        #expect(led <= 2 * alone, "\(Int(display)) Hz: \(alone) pt/frame alone, \(led) with the lead")
    }

    @Test func theLeadLeavesAStillHeadsDotExactlyWhereItWas() {
        for seed in UInt64(1)...8 {
            let alone = run(seconds: 6, noise: 0.004, seed: seed) { _ in 0 }.map(\.dot)
            let led = run(seconds: 6, noise: 0.004, seed: seed, lead: true) { _ in 0 }.map(\.dot)
            #expect(alone == led, "seed \(seed)")
        }
    }

    @Test func aStillHeadKeepsTheDotWithinTwoPoints() {
        // 0.004 rad of noise is about 10 pt on screen per reading.
        for seed in UInt64(1)...8 {
            let dots = run(seconds: 6, noise: 0.004, seed: seed) { _ in 0 }.filter { $0.t >= 2 }.map(\.dot)
            let mx = dots.map(\.x).reduce(0, +) / CGFloat(dots.count), my = dots.map(\.y).reduce(0, +) / CGFloat(dots.count)
            let worst = dots.map { hypot($0.x - mx, $0.y - my) }.max() ?? 0
            #expect(worst <= 2, "seed \(seed): dot moved \(worst) pt while the head was still")
        }
    }

    @Test func aStepIsNinetyPercentCoveredWithinFourHundredMilliseconds() {
        for seed in UInt64(1)...8 {
            let size = 300.0
            let dots = run(seconds: 4, noise: 0.004, seed: seed) { $0 < 2 ? 0 : size / 2400 }
            let x0 = 960.0
            let hit = dots.first { $0.t >= 2 && Double($0.dot.x) >= x0 + 0.9 * size }
            #expect(hit != nil && hit!.t - 2 <= 0.4, "seed \(seed): 90% at \(hit.map { $0.t - 2 } ?? -1) s")
            // And it comes to rest near the aim, not a leash short of it.
            let end = dots.last!.dot
            #expect(abs(Double(end.x) - (x0 + size)) <= 10)
        }
    }
}

@Suite struct PointerSmoothingTests {
    @Test func sliderEndsAndDefault() {
        let light = PointerSmoothing.level(0), steady = PointerSmoothing.level(1)
        #expect(light.minCutoff > steady.minCutoff && light.beta > steady.beta)
        #expect(PointerSmoothing.level(.nan) == PointerSmoothing.level(PointerSmoothing.defaultLevel))
        #expect(PointerSmoothing.level(5) == steady)
    }
}

@Suite struct CameraFormatChoiceTests {
    typealias F = CameraFormatChoice.Format

    @Test func prefersExactVGAAtThirtyOverLargerFormats() {
        let formats = [F(width: 1280, height: 720, maxRate: 30, compressed: true),
                       F(width: 640, height: 480, maxRate: 30, compressed: false),
                       F(width: 1920, height: 1080, maxRate: 30, compressed: true)]
        #expect(CameraFormatChoice.pick(formats) == 1)
    }

    @Test func aFormatThatReachesThirtyBeatsASmallerSlowerOne() {
        let formats = [F(width: 640, height: 480, maxRate: 15, compressed: false),
                       F(width: 800, height: 600, maxRate: 30, compressed: false)]
        #expect(CameraFormatChoice.pick(formats) == 1)
        #expect(CameraFormatChoice.rate(for: formats[1]) == 30)
    }

    @Test func uncompressedWinsATie() {
        let formats = [F(width: 640, height: 480, maxRate: 30, compressed: true),
                       F(width: 640, height: 480, maxRate: 30, compressed: false)]
        #expect(CameraFormatChoice.pick(formats) == 1)
    }

    @Test func aSlowCameraGetsItsBestRate() {
        let formats = [F(width: 640, height: 480, maxRate: 20, compressed: false),
                       F(width: 640, height: 480, maxRate: 24, compressed: false)]
        #expect(CameraFormatChoice.pick(formats) == 1)
        #expect(CameraFormatChoice.rate(for: formats[1]) == 24)
        #expect(CameraFormatChoice.rate(for: F(width: 640, height: 480, maxRate: 60, compressed: false)) == 30)
    }

    @Test func tooSmallOrTooLargeKeepsThePreset() {
        #expect(CameraFormatChoice.pick([F(width: 320, height: 240, maxRate: 30, compressed: false),
                                         F(width: 1920, height: 1080, maxRate: 30, compressed: false)]) == nil)
        #expect(CameraFormatChoice.pick([]) == nil)
    }
}
