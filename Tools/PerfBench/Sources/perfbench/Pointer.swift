import CoreGraphics
import EnsembleCore
import Foundation

/// Replays synthetic head paths through the app's pointer filter (NosePointer), the dot.s rest rule (NoseDot) and the
/// on-screen motion, at a chosen head-reading rate and display rate, and reports what the eye sees:
/// jitter while still, lag after a step, judder while panning, and how far the dot rests from the aim.
/// Deterministic: the noise comes from a seeded generator.
struct PointerPipeline {
    var name: String
    var readingsPerSecond: Double
    var smoothing: PointerSmoothing
    /// The screen's refresh rate (Hz). At 120 the dot is redrawn on every refresh only while it moves fast, as GlassDot asks.
    var display = 60.0
    /// The spring aims ahead of the reading while the dot moves (`DotLead`).
    var lead = false
    /// The old hard leash (pt), used when `wakeRadius` is nil.
    var leash: CGFloat = 24
    /// The new rest rule's wake radius (pt); nil replays the old leash.
    var wakeRadius: CGFloat?
    /// nil: the old exponential glide with this time constant (s). Otherwise the spring's omega.
    var glide: Double?
    var springOmega: Double = 32
    var wakeReadings = NoseDot().wakeReadings
}

private struct SplitMix {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

struct PointerResult {
    var stillRMS = 0.0       // pt, dot about its own mean while the head is still
    var stillMax = 0.0       // pt, largest distance from that mean
    var lag90 = 0.0          // ms from a 300 pt step to the dot covering 90% of it
    var restError = 0.0      // pt, dot to true aim once the step has settled
    var panJudder = 0.0      // pt per display frame, RMS deviation from steady motion while panning
    var panTrail = 0.0       // pt the dot trails the true aim while panning
}

enum PointerBench {
    // Ground truth like the unit tests: x = 2400 yaw + 960, y = 2000 pitch + 540 (points per radian).
    static let ptPerYaw = 2400.0, ptPerPitch = 2000.0

    static func pointer(_ p: PointerPipeline) -> NosePointer {
        let n = NosePointer()
        var samples: [CalibrationSample] = []
        for yaw in [-0.25, 0, 0.25] {
            for pitch in [-0.15, 0, 0.15] {
                samples.append(CalibrationSample(yaw: yaw, pitch: pitch,
                                                 target: CGPoint(x: ptPerYaw * yaw + 960, y: ptPerPitch * pitch + 540)))
            }
        }
        n.fit(samples)
        n.setSmoothing(p.smoothing)
        return n
    }

    /// Runs one head path. `aim(t)` is the true yaw (pitch stays 0 plus noise). Returns the dot and the true aim at
    /// every display frame.
    static func run(_ p: PointerPipeline, seconds: Double, noise: Double, seed: UInt64, phase: Double,
                    aim: (Double) -> Double) -> [(t: Double, dot: CGPoint, truth: CGPoint)] {
        var rng = SplitMix(state: seed)
        let pointer = pointer(p)
        var leashed: CGPoint?
        var rest = NoseDot()
        if let r = p.wakeRadius { rest.wakeRadius = r }
        rest.wakeReadings = p.wakeReadings
        var spring = DotSpring(omega: p.springOmega)
        var drawn: CGPoint?
        var ahead: DotLead?
        var lastReading: Double?
        var lastTick: Double?
        var nextReading = phase / p.readingsPerSecond
        var out: [(Double, CGPoint, CGPoint)] = []
        let display = p.display
        let frames = Int(seconds * display)
        for f in 0..<frames {
            let t = Double(f) / display
            while nextReading <= t {
                let yaw = aim(nextReading) + noise * rng.gaussian()
                let pitch = noise * rng.gaussian()
                if let q = pointer.point(for: HeadObservation(t: nextReading, yaw: yaw, pitch: pitch, faceCount: 1)) {
                    if p.wakeRadius != nil {
                        leashed = rest.follow(nose: q, at: nextReading)
                        ahead = p.lead && rest.moving
                            ? DotLead(point: q, t: nextReading, velocity: pointer.velocity, aim: pointer.aim ?? q,
                                      interval: nextReading - (lastReading ?? nextReading - 1 / p.readingsPerSecond))
                            : nil
                        lastReading = nextReading
                    } else if let d = leashed {
                        // The old NoseDot: a hard leash; the dot stays put inside it and trails by it outside.
                        let dist = hypot(q.x - d.x, q.y - d.y)
                        leashed = dist > p.leash ? CGPoint(x: d.x + (q.x - d.x) * (dist - p.leash) / dist, y: d.y + (q.y - d.y) * (dist - p.leash) / dist) : d
                    } else {
                        leashed = q
                    }
                }
                nextReading += 1 / p.readingsPerSecond
            }
            guard let goal = leashed else { continue }
            if let tau = p.glide {
                // The old GlassDot: an exponential glide toward the latest goal, stopping inside 0.25 pt.
                let from = drawn ?? goal
                let k = 1 - exp(-(1 / display) / tau)
                var next = CGPoint(x: from.x + (goal.x - from.x) * k, y: from.y + (goal.y - from.y) * k)
                if hypot(goal.x - next.x, goal.y - next.y) < 0.25 { next = goal }
                drawn = next
            } else {
                // Above 60 Hz a slow dot is redrawn on every second refresh only; the screen shows the last one meanwhile.
                if display > 60, !spring.isFast, f % 2 == 1 { continue }
                if spring.position == nil { spring.reset(to: goal) }
                drawn = spring.step(toward: ahead?.goal(at: t) ?? goal, dt: t - (lastTick ?? t - 1 / display))
                lastTick = t
            }
            out.append((t, drawn!, CGPoint(x: ptPerYaw * aim(t) + 960, y: 540)))
        }
        return out
    }

    static func measure(_ p: PointerPipeline, noise: Double, seeds: Int = 40) -> PointerResult {
        var r = PointerResult()
        var lagSum = 0.0, restSum = 0.0, rmsSum = 0.0, maxSum = 0.0, judderSum = 0.0, trailSum = 0.0
        for s in 0..<seeds {
            let seed = UInt64(1000 + s)
            let phase = Double(s) / Double(seeds)
            do { let pipe = p
                // Still: 6 s at the centre; measure the last 4 s.
                let still = run(pipe, seconds: 6, noise: noise, seed: seed, phase: phase) { _ in 0 }.filter { $0.t >= 2 }
                let mx = still.map(\.dot.x).reduce(0, +) / Double(still.count)
                let my = still.map(\.dot.y).reduce(0, +) / Double(still.count)
                let d = still.map { Double(hypot($0.dot.x - mx, $0.dot.y - my)) }
                rmsSum += (d.map { $0 * $0 }.reduce(0, +) / Double(d.count)).squareRoot()
                maxSum += d.max() ?? 0

                // Step: 2 s still, then 300 pt to the right, held 3 s.
                let stepAt = 2.0, size = 300.0
                let step = run(pipe, seconds: 5, noise: noise, seed: seed, phase: phase) { $0 < stepAt ? 0 : size / ptPerYaw }
                let before = step.filter { $0.t > stepAt - 0.5 && $0.t < stepAt }.map(\.dot.x)
                let x0 = Double(before.reduce(0, +)) / Double(max(before.count, 1))
                let hit = step.first { $0.t >= stepAt && Double($0.dot.x) >= x0 + 0.9 * (960 + size - x0) }
                lagSum += ((hit?.t ?? 5) - stepAt) * 1000
                let settled = step.filter { $0.t > 4.5 }
                restSum += settled.map { Double(hypot($0.dot.x - $0.truth.x, $0.dot.y - $0.truth.y)) }.reduce(0, +) / Double(settled.count)

                // Pan: still 1.5 s, then 600 pt/s to the right for 1.5 s; measure the middle second.
                let pan = run(pipe, seconds: 3, noise: noise, seed: seed, phase: phase) { t in t < 1.5 ? 0 : (t - 1.5) * 600 / ptPerYaw }
                let mid = pan.filter { $0.t >= 1.8 && $0.t <= 2.8 }
                var steps: [Double] = []
                for i in 1..<mid.count { steps.append(Double(mid[i].dot.x - mid[i - 1].dot.x)) }
                let mean = steps.reduce(0, +) / Double(steps.count)
                judderSum += (steps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(steps.count)).squareRoot()
                trailSum += mid.map { Double($0.truth.x - $0.dot.x) }.reduce(0, +) / Double(mid.count)
            }
        }
        let n = Double(seeds)
        r.stillRMS = rmsSum / n; r.stillMax = maxSum / n; r.lag90 = lagSum / n; r.restError = restSum / n
        r.panJudder = judderSum / n; r.panTrail = trailSum / n
        return r
    }

    static func report(_ p: PointerPipeline, noise: Double) {
        let r = measure(p, noise: noise)
        print(String(format: "  %-34@ still %5.2f pt rms (max %5.1f) | step lag90 %4.0f ms, rests %4.1f pt off | pan judder %4.2f pt/frame, trails %5.1f pt",
                     p.name as NSString, r.stillRMS, r.stillMax, r.lag90, r.restError, r.panJudder, r.panTrail))
    }
}

func runPointer(_ args: [String]) {
    var noise = 0.004
    var sweep = false
    for a in args {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2, kv[0] == "noise", let v = Double(kv[1]) { noise = v }
        if a == "sweep" { sweep = true }
    }
    let old = PointerSmoothing(minCutoff: 1.0 - 0.9 * 0.7, beta: 4.0 - 3.4 * 0.7, dCutoff: 1)
    print(String(format: "pointer replay: head noise %.4f rad (%.1f pt), 60 Hz display unless a row says 120, 40 seeds", noise, noise * PointerBench.ptPerYaw))
    let new = PointerSmoothing.level(PointerSmoothing.defaultLevel)
    let rows: [PointerPipeline] = [
        PointerPipeline(name: "before, 21 fps camera (10.5 Hz face)", readingsPerSecond: 10.5, smoothing: old, leash: 24, glide: 0.05),
        PointerPipeline(name: "before, 30 fps camera (15 Hz face)", readingsPerSecond: 15, smoothing: old, leash: 24, glide: 0.05),
        PointerPipeline(name: "after, 21 fps camera (every frame)", readingsPerSecond: 21, smoothing: new, wakeRadius: NoseDot().wakeRadius, glide: nil),
        PointerPipeline(name: "after, 30 fps camera (every frame)", readingsPerSecond: 30, smoothing: new, wakeRadius: NoseDot().wakeRadius, glide: nil),
        PointerPipeline(name: "after, 30 fps, slider at 0.7", readingsPerSecond: 30, smoothing: .level(0.7), wakeRadius: NoseDot().wakeRadius, glide: nil),
        PointerPipeline(name: "lead, 30 fps camera", readingsPerSecond: 30, smoothing: new, lead: true, wakeRadius: NoseDot().wakeRadius, glide: nil),
        PointerPipeline(name: "after, 30 fps, 120 Hz", readingsPerSecond: 30, smoothing: new, display: 120, wakeRadius: NoseDot().wakeRadius, glide: nil),
        PointerPipeline(name: "lead, 30 fps, 120 Hz", readingsPerSecond: 30, smoothing: new, display: 120, lead: true, wakeRadius: NoseDot().wakeRadius, glide: nil),
    ]
    rows.forEach { PointerBench.report($0, noise: noise) }
    guard sweep else { return }
    print("sweep at 30 Hz readings (noise 0.004 / 0.008 / 0.012 rad), best first:")
    var found: [(String, [PointerResult])] = []
    for mc in [0.1, 0.2, 0.35] { for beta in [1.0, 2, 4] { for dc in [0.5, 1] { for wake in [16.0, 24, 32] as [CGFloat] { for reads in [2, 3] {
        var pipe = PointerPipeline(name: "", readingsPerSecond: 30, smoothing: PointerSmoothing(minCutoff: mc, beta: beta, dCutoff: dc), wakeRadius: wake, glide: nil)
        pipe.wakeReadings = reads
        let r = [0.004, 0.008, 0.012].map { PointerBench.measure(pipe, noise: $0, seeds: 12) }
        if r.allSatisfy({ $0.lag90 < 400 }) { found.append((String(format: "mc %.2f beta %.0f dc %.1f wake %.0f x%d", mc, beta, dc, wake, reads), r)) }
    } } } } }
    func score(_ r: [PointerResult]) -> Double { r.map { $0.stillRMS + 0.3 * $0.stillMax + 0.5 * $0.restError + $0.lag90 / 100 }.reduce(0, +) }
    for (n, r) in found.sorted(by: { score($0.1) < score($1.1) }).prefix(25) {
        print("  " + n.padding(toLength: 32, withPad: " ", startingAt: 0) + r.map { String(format: "| still %5.2f max %4.1f rest %4.1f lag %3.0f judder %4.2f ", $0.stillRMS, $0.stillMax, $0.restError, $0.lag90, $0.panJudder) }.joined())
    }
}
