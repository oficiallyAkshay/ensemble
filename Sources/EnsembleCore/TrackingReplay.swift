import Foundation

/// One head reading as the detailed trace records it: no image data, only counts and numbers.
public struct TrackSample: Equatable, Sendable {
    public var t: TimeInterval
    public var faces: Int
    public var nose: CGPoint?
    /// The latest brightness reading, which is held for up to 0.1 s: it is not measured on every head reading.
    public var luma: Double?
    public init(t: TimeInterval, faces: Int, nose: CGPoint? = nil, luma: Double? = nil) {
        self.t = t; self.faces = faces; self.nose = nose; self.luma = luma
    }

    /// The trace line a head reading writes, after the time stamp.
    public var traceLine: String {
        let n = nose.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
        return "read faces=\(faces) nose=\(n) luma=\(luma.map { String(format: "%.3f", $0) } ?? "-")"
    }
}

/// The three numbers that compare tracking across lighting, read from a saved trace.
public struct TrackingMetrics: Equatable, Sendable {
    /// Share of head readings that saw no face.
    public var lostFaceRate: Double
    /// Root-mean-square distance, in screen points, of the nose from its resting spot while the head was still. nil when the head was never still for a second.
    public var stillWander: Double?
    /// Average seconds the nose took to go from 10% to 90% of the way across a step between two resting spots. nil when the recording holds no step.
    /// The trace holds the dot's position, not the head's, so this is how slowly the dot crosses, not its delay behind the head.
    public var followLag: Double?
    /// Average brightness of the readings that carried one, for telling the conditions apart.
    public var meanLuma: Double?
    public var readings: Int
}

public enum TrackingReplay {
    static let window = 0.3
    static let maxHole = 0.5
    static let stillBelow = 100.0
    static let minStill = 1.0
    static let minStep = 100.0
    static let maxGap = 3.0

    /// Reads the `read` lines of a trace file; every other line is ignored.
    public static func samples(fromTrace text: String) -> [TrackSample] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 5, f[1] == "read", let t = Double(f[0]), let faces = Int(f[2].dropFirst("faces=".count)) else { return nil }
            let xy = f[3].dropFirst("nose=".count).split(separator: ",").compactMap { Double($0) }
            return TrackSample(t: t, faces: faces, nose: xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil, luma: Double(f[4].dropFirst("luma=".count)))
        }
    }

    public static func metrics(of samples: [TrackSample]) -> TrackingMetrics {
        let lost = samples.filter { $0.faces == 0 }.count
        let lumas = samples.compactMap(\.luma)
        let tracked = samples.filter { $0.faces == 1 && $0.nose != nil }
        let runs = stillRuns(tracked)

        var squares = 0.0, count = 0
        for run in runs {
            let c = centre(run)
            for s in run { squares += dist(s.nose!, c) * dist(s.nose!, c); count += 1 }
        }

        var lags: [Double] = []
        for (a, b) in zip(runs, runs.dropFirst()) {
            let from = centre(a), to = centre(b)
            let d = dist(from, to)
            guard d >= minStep, b[0].t - a[a.count - 1].t <= maxGap else { continue }
            let after = tracked.filter { $0.t > a[a.count - 1].t }
            func first(reaching share: Double) -> TimeInterval? {
                after.first { ((($0.nose!.x - from.x) * (to.x - from.x) + ($0.nose!.y - from.y) * (to.y - from.y)) / (d * d)) >= share }?.t
            }
            if let left = first(reaching: 0.1), let arrived = first(reaching: 0.9) { lags.append(arrived - left) }
        }

        return TrackingMetrics(
            lostFaceRate: samples.isEmpty ? 0 : Double(lost) / Double(samples.count),
            stillWander: count == 0 ? nil : (squares / Double(count)).squareRoot(),
            followLag: lags.isEmpty ? nil : lags.reduce(0, +) / Double(lags.count),
            meanLuma: lumas.isEmpty ? nil : lumas.reduce(0, +) / Double(lumas.count),
            readings: samples.count)
    }

    /// Stretches of at least a second where the nose moved under 100 points a second both over the 0.3 s before each
    /// reading and the 0.3 s after it, so the first readings of a move and the last of a settle do not count as still.
    private static func stillRuns(_ s: [TrackSample]) -> [[TrackSample]] {
        var runs: [[TrackSample]] = [], current: [TrackSample] = []
        func close() {
            if let first = current.first, current[current.count - 1].t - first.t >= minStill { runs.append(current) }
            current = []
        }
        var back = 0, ahead = 0
        for i in s.indices {
            while back < i, s[back + 1].t <= s[i].t - window { back += 1 }
            while ahead < s.count - 1, s[ahead].t < s[i].t + window { ahead += 1 }
            let enclosed = s[back].t <= s[i].t - window && s[ahead].t >= s[i].t + window
            let still = enclosed && dist(s[i].nose!, s[back].nose!) / window < stillBelow && dist(s[i].nose!, s[ahead].nose!) / window < stillBelow
            if still, let last = current.last, s[i].t - last.t > maxHole { close() }
            if still { current.append(s[i]) } else { close() }
        }
        close()
        return runs
    }

    private static func centre(_ run: [TrackSample]) -> CGPoint {
        CGPoint(x: run.map { $0.nose!.x }.reduce(0, +) / Double(run.count), y: run.map { $0.nose!.y }.reduce(0, +) / Double(run.count))
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
}
